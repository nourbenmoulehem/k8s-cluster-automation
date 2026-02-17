#!/usr/bin/env python3
"""
Claude Observer - AI-Powered Kubernetes Monitoring
Analyzes cluster metrics and makes intelligent predictions
"""

import os
import time
import json
from datetime import datetime
from kubernetes import client, config
import anthropic

# Configuration
ANTHROPIC_API_KEY = os.getenv('ANTHROPIC_API_KEY')
CHECK_INTERVAL = 300  # 5 minutes
OUTPUT_FILE = '/tmp/claude-observer-latest.txt'

def get_cluster_metrics():
    """Gather key metrics from Kubernetes cluster"""
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    
    metrics = {
        'timestamp': datetime.now().isoformat(),
        'nodes': [],
        'pods': [],
        'deployments': []
    }
    
    # Get nodes
    for node in v1.list_node().items:
        node_info = {
            'name': node.metadata.name,
            'status': 'Ready' if any(c.type == 'Ready' and c.status == 'True' 
                                     for c in node.status.conditions) else 'NotReady',
            'capacity': {
                'cpu': node.status.capacity.get('cpu'),
                'memory': node.status.capacity.get('memory'),
            }
        }
        metrics['nodes'].append(node_info)
    
    # Get pods
    for pod in v1.list_pod_for_all_namespaces().items:
        if pod.metadata.namespace in ['kube-system', 'local-path-storage', 'monitoring']:
            continue  # Skip system pods
            
        pod_info = {
            'name': pod.metadata.name,
            'namespace': pod.metadata.namespace,
            'node': pod.spec.node_name,
            'status': pod.status.phase,
            'restarts': sum(c.restart_count for c in pod.status.container_statuses or []),
            'ready': f"{sum(1 for c in pod.status.container_statuses or [] if c.ready)}/{len(pod.spec.containers)}"
        }
        
        # Get container resource requests/limits
        for container in pod.spec.containers:
            if container.resources.requests:
                pod_info['requests'] = {
                    'cpu': container.resources.requests.get('cpu'),
                    'memory': container.resources.requests.get('memory')
                }
            if container.resources.limits:
                pod_info['limits'] = {
                    'cpu': container.resources.limits.get('cpu'),
                    'memory': container.resources.limits.get('memory')
                }
        
        metrics['pods'].append(pod_info)
    
    # Get deployments
    for deploy in apps_v1.list_deployment_for_all_namespaces().items:
        if deploy.metadata.namespace in ['kube-system', 'local-path-storage', 'monitoring']:
            continue
            
        deploy_info = {
            'name': deploy.metadata.name,
            'namespace': deploy.metadata.namespace,
            'replicas': deploy.spec.replicas,
            'ready_replicas': deploy.status.ready_replicas or 0,
            'available_replicas': deploy.status.available_replicas or 0
        }
        metrics['deployments'].append(deploy_info)
    
    # Get recent events
    events = v1.list_event_for_all_namespaces(limit=20)
    metrics['recent_events'] = []
    for event in events.items:
        if event.type == 'Warning' or event.reason in ['Failed', 'BackOff', 'FailedScheduling']:
            metrics['recent_events'].append({
                'type': event.type,
                'reason': event.reason,
                'message': event.message,
                'object': f"{event.involved_object.kind}/{event.involved_object.name}",
                'count': event.count,
                'last_seen': event.last_timestamp.isoformat() if event.last_timestamp else 'Unknown'
            })
    
    return metrics

def analyze_with_claude(metrics):
    """Send metrics to Claude for AI analysis"""
    if not ANTHROPIC_API_KEY:
        return "Error: ANTHROPIC_API_KEY not set"
    
    client_anthropic = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
    
    prompt = f"""You are an expert Kubernetes SRE analyzing cluster health. Analyze these metrics and provide:

1. **Health Summary**: Overall cluster health (Good/Warning/Critical)
2. **Issues Detected**: Any problems or concerning patterns
3. **Predictions**: What might happen in the next few hours based on trends
4. **Recommendations**: Specific actions to take

Cluster Metrics:
```json
{json.dumps(metrics, indent=2)}
```

Be concise and actionable. Focus on:
- Pods with restarts (might indicate instability)
- Resource utilization patterns
- Deployment health (replicas ready vs desired)
- Warning events that need attention
- Potential issues before they become critical

Format your response clearly with headers."""

    try:
        message = client_anthropic.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=1500,
            messages=[{"role": "user", "content": prompt}]
        )
        
        analysis = message.content[0].text
        return analysis
    
    except Exception as e:
        return f"Error calling Claude API: {str(e)}"

def save_report(metrics, analysis):
    """Save analysis report to file"""
    report = f"""
{'='*80}
CLAUDE OBSERVER REPORT
Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}
{'='*80}

CLUSTER SNAPSHOT:
- Nodes: {len(metrics['nodes'])} ({sum(1 for n in metrics['nodes'] if n['status'] == 'Ready')} Ready)
- Pods: {len(metrics['pods'])} ({sum(1 for p in metrics['pods'] if p['status'] == 'Running')} Running)
- Deployments: {len(metrics['deployments'])}
- Recent Warning Events: {len(metrics['recent_events'])}

{'='*80}
AI ANALYSIS:
{'='*80}

{analysis}

{'='*80}
RAW METRICS:
{'='*80}
{json.dumps(metrics, indent=2)}
"""
    
    with open(OUTPUT_FILE, 'w') as f:
        f.write(report)
    
    print(f"[{datetime.now()}] Report saved to {OUTPUT_FILE}")
    print(f"\nPreview:\n{analysis[:500]}...")

def main():
    """Main monitoring loop"""
    print(f"Claude Observer starting...")
    print(f"API Key configured: {'Yes' if ANTHROPIC_API_KEY else 'No'}")
    print(f"Check interval: {CHECK_INTERVAL}s")
    print(f"Output file: {OUTPUT_FILE}")
    print("-" * 80)
    
    iteration = 0
    while True:
        iteration += 1
        print(f"\n[Iteration {iteration}] Collecting metrics...")
        
        try:
            # Gather metrics
            metrics = get_cluster_metrics()
            print(f"  ✓ Collected: {len(metrics['nodes'])} nodes, {len(metrics['pods'])} pods")
            
            # Analyze with AI
            print(f"  → Sending to Claude for analysis...")
            analysis = analyze_with_claude(metrics)
            print(f"  ✓ Analysis complete")
            
            # Save report
            save_report(metrics, analysis)
            print(f"  ✓ Report saved")
            
        except Exception as e:
            print(f"  ✗ Error: {str(e)}")
        
        # Wait for next check
        print(f"\nNext check in {CHECK_INTERVAL}s...")
        time.sleep(CHECK_INTERVAL)

if __name__ == '__main__':
    main()

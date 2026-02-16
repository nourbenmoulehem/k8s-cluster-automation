#!/usr/bin/env python3
"""
Claude Observer - AI-Powered Kubernetes Monitoring Agent
Continuously monitors cluster health and provides intelligent insights
"""

import os
import time
import requests
import anthropic
from datetime import datetime, timedelta
from typing import Dict, List, Optional

class ClaudeObserver:
    def __init__(self):
        self.claude_client = anthropic.Anthropic(
            api_key=os.environ.get("ANTHROPIC_API_KEY")
        )
        self.prometheus_url = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
        self.check_interval = int(os.environ.get("CHECK_INTERVAL", "300"))  # 5 minutes
        self.model = "claude-sonnet-4-20250514"
        
        # Context storage for historical analysis
        self.historical_context = []
        
    def query_prometheus(self, query: str, time_range: str = "5m") -> Dict:
        """Query Prometheus for metrics"""
        try:
            response = requests.get(
                f"{self.prometheus_url}/api/v1/query",
                params={"query": query}
            )
            return response.json()
        except Exception as e:
            print(f"Error querying Prometheus: {e}")
            return {}
    
    def get_cluster_metrics(self) -> Dict:
        """Gather comprehensive cluster metrics"""
        metrics = {}
        
        # CPU and Memory usage per pod
        metrics['pod_cpu'] = self.query_prometheus(
            'sum(rate(container_cpu_usage_seconds_total[5m])) by (pod, namespace)'
        )
        metrics['pod_memory'] = self.query_prometheus(
            'sum(container_memory_usage_bytes) by (pod, namespace)'
        )
        
        # Node metrics
        metrics['node_cpu'] = self.query_prometheus(
            'sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)'
        )
        metrics['node_memory'] = self.query_prometheus(
            'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes'
        )
        
        # Pod restarts (anomaly detection)
        metrics['pod_restarts'] = self.query_prometheus(
            'increase(kube_pod_container_status_restarts_total[5m]) > 0'
        )
        
        # Service latency (if available)
        metrics['http_latency'] = self.query_prometheus(
            'histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))'
        )
        
        # HPA metrics
        metrics['hpa_replicas'] = self.query_prometheus(
            'kube_horizontalpodautoscaler_status_current_replicas'
        )
        
        return metrics
    
    def detect_anomalies(self, metrics: Dict) -> Optional[str]:
        """Use Claude to detect anomalies"""
        
        # Build context for Claude
        context = f"""
        Analyze the following Kubernetes cluster metrics for anomalies:
        
        Timestamp: {datetime.now().isoformat()}
        
        CPU Usage (pods):
        {self._format_metrics(metrics.get('pod_cpu', {}))}
        
        Memory Usage (pods):
        {self._format_metrics(metrics.get('pod_memory', {}))}
        
        Node CPU:
        {self._format_metrics(metrics.get('node_cpu', {}))}
        
        Pod Restarts (last 5 min):
        {self._format_metrics(metrics.get('pod_restarts', {}))}
        
        HTTP Latency (p99):
        {self._format_metrics(metrics.get('http_latency', {}))}
        
        Historical Context (last 3 checks):
        {self._format_historical_context()}
        
        Tasks:
        1. Detect any anomalies (unusual CPU/memory spikes, excessive restarts, high latency)
        2. Identify the severity (low/medium/high)
        3. Suggest immediate actions if needed
        4. Provide context about what might be causing the issue
        
        Format your response as:
        ANOMALIES DETECTED: yes/no
        SEVERITY: low/medium/high
        DETAILS: [explanation]
        RECOMMENDED ACTIONS: [specific kubectl commands or config changes]
        """
        
        try:
            message = self.claude_client.messages.create(
                model=self.model,
                max_tokens=2000,
                messages=[{"role": "user", "content": context}]
            )
            
            analysis = message.content[0].text
            
            # Store in historical context
            self.historical_context.append({
                'timestamp': datetime.now().isoformat(),
                'metrics': metrics,
                'analysis': analysis
            })
            
            # Keep only last 10 checks
            if len(self.historical_context) > 10:
                self.historical_context.pop(0)
            
            return analysis
            
        except Exception as e:
            print(f"Error analyzing with Claude: {e}")
            return None
    
    def predict_load(self, metrics: Dict) -> Optional[str]:
        """Use Claude to predict future load patterns"""
        
        if len(self.historical_context) < 3:
            return None  # Need historical data
        
        context = f"""
        Based on the following historical metrics, predict load patterns for the next hour:
        
        Historical Data (last 30 minutes):
        {self._format_historical_metrics()}
        
        Current Time: {datetime.now().isoformat()}
        Current Metrics:
        {self._format_metrics(metrics.get('pod_cpu', {}))}
        
        Tasks:
        1. Identify any patterns or trends
        2. Predict if load will increase/decrease in the next 1-2 hours
        3. Estimate confidence level (low/medium/high)
        4. Recommend if preemptive scaling is needed
        
        Format:
        PREDICTION: [increase/decrease/stable]
        CONFIDENCE: [low/medium/high]
        TIMEFRAME: [when the change is expected]
        RECOMMENDED ACTION: [scale up/down/maintain, with specific replica counts]
        """
        
        try:
            message = self.claude_client.messages.create(
                model=self.model,
                max_tokens=1500,
                messages=[{"role": "user", "content": context}]
            )
            
            return message.content[0].text
            
        except Exception as e:
            print(f"Error predicting load: {e}")
            return None
    
    def recommend_optimizations(self, metrics: Dict) -> Optional[str]:
        """Get resource optimization recommendations"""
        
        context = f"""
        Analyze the following Kubernetes cluster resource usage and provide optimization recommendations:
        
        Pod Resource Usage:
        CPU: {self._format_metrics(metrics.get('pod_cpu', {}))}
        Memory: {self._format_metrics(metrics.get('pod_memory', {}))}
        
        Node Resources:
        {self._format_metrics(metrics.get('node_cpu', {}))}
        
        Tasks:
        1. Identify pods that are over-provisioned (requesting more than they use)
        2. Identify pods that are under-provisioned (at risk of OOMKill or throttling)
        3. Suggest specific resource requests/limits changes
        4. Recommend pod placement improvements for better load balancing
        
        Provide specific YAML patches that can be applied.
        """
        
        try:
            message = self.claude_client.messages.create(
                model=self.model,
                max_tokens=2000,
                messages=[{"role": "user", "content": context}]
            )
            
            return message.content[0].text
            
        except Exception as e:
            print(f"Error getting recommendations: {e}")
            return None
    
    def check_ha_resilience(self, metrics: Dict) -> Optional[str]:
        """Analyze high availability and resilience"""
        
        restarts = metrics.get('pod_restarts', {})
        
        context = f"""
        Analyze the high availability and resilience of the Kubernetes cluster:
        
        Pod Restarts (last 5 min):
        {self._format_metrics(restarts)}
        
        HPA Status:
        {self._format_metrics(metrics.get('hpa_replicas', {}))}
        
        Tasks:
        1. Identify any pods with frequent restarts
        2. Check if pod distribution is resilient
        3. Verify HPA is functioning correctly
        4. Suggest improvements for better resilience
        
        Focus on:
        - Single points of failure
        - Pods not managed by controllers
        - Missing readiness/liveness probes
        - Inadequate replica counts
        """
        
        try:
            message = self.claude_client.messages.create(
                model=self.model,
                max_tokens=1500,
                messages=[{"role": "user", "content": context}]
            )
            
            return message.content[0].text
            
        except Exception as e:
            print(f"Error checking HA: {e}")
            return None
    
    def _format_metrics(self, metric_data: Dict) -> str:
        """Format Prometheus metrics for Claude"""
        if not metric_data or 'data' not in metric_data:
            return "No data available"
        
        result = metric_data['data'].get('result', [])
        if not result:
            return "No metrics found"
        
        lines = []
        for item in result[:20]:  # Limit to 20 items
            metric = item.get('metric', {})
            value = item.get('value', [None, 'N/A'])
            lines.append(f"  {metric}: {value[1]}")
        
        return "\n".join(lines)
    
    def _format_historical_context(self) -> str:
        """Format historical context for Claude"""
        if not self.historical_context:
            return "No historical data yet"
        
        lines = []
        for entry in self.historical_context[-3:]:  # Last 3 checks
            lines.append(f"\n[{entry['timestamp']}]")
            lines.append(f"Summary: {entry['analysis'][:200]}...")
        
        return "\n".join(lines)
    
    def _format_historical_metrics(self) -> str:
        """Format historical metrics for trend analysis"""
        if not self.historical_context:
            return "No historical data"
        
        lines = []
        for entry in self.historical_context:
            lines.append(f"\n[{entry['timestamp']}]")
            cpu_data = entry['metrics'].get('pod_cpu', {})
            lines.append(f"CPU: {self._format_metrics(cpu_data)[:100]}")
        
        return "\n".join(lines)
    
    def generate_report(self, anomalies, predictions, recommendations, ha_check):
        """Generate comprehensive report"""
        report = f"""
        ╔══════════════════════════════════════════════════════════════╗
        ║          Claude Observer - Cluster Analysis Report           ║
        ║                  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}                    ║
        ╚══════════════════════════════════════════════════════════════╝
        
        {'='*60}
        ANOMALY DETECTION
        {'='*60}
        {anomalies or 'No analysis available'}
        
        {'='*60}
        LOAD PREDICTION
        {'='*60}
        {predictions or 'Insufficient historical data'}
        
        {'='*60}
        RESOURCE RECOMMENDATIONS
        {'='*60}
        {recommendations or 'No recommendations at this time'}
        
        {'='*60}
        HIGH AVAILABILITY CHECK
        {'='*60}
        {ha_check or 'No HA issues detected'}
        
        ╚══════════════════════════════════════════════════════════════╝
        """
        
        return report
    
    def run(self):
        """Main monitoring loop"""
        print(f"🤖 Claude Observer starting...")
        print(f"   Prometheus: {self.prometheus_url}")
        print(f"   Check interval: {self.check_interval}s")
        print(f"   Model: {self.model}")
        print()
        
        iteration = 0
        
        while True:
            iteration += 1
            print(f"\n{'='*60}")
            print(f"Iteration {iteration} - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            print(f"{'='*60}\n")
            
            # Gather metrics
            print("📊 Gathering cluster metrics...")
            metrics = self.get_cluster_metrics()
            
            # Run analyses
            print("🔍 Detecting anomalies...")
            anomalies = self.detect_anomalies(metrics)
            
            print("📈 Predicting load patterns...")
            predictions = self.predict_load(metrics)
            
            print("💡 Generating recommendations...")
            recommendations = self.recommend_optimizations(metrics)
            
            print("🛡️  Checking high availability...")
            ha_check = self.check_ha_resilience(metrics)
            
            # Generate and display report
            report = self.generate_report(anomalies, predictions, recommendations, ha_check)
            print(report)
            
            # Save report to file (for web dashboard later)
            with open('/tmp/claude-observer-latest.txt', 'w') as f:
                f.write(report)
            
            print(f"\n⏳ Next check in {self.check_interval} seconds...")
            time.sleep(self.check_interval)

if __name__ == "__main__":
    observer = ClaudeObserver()
    observer.run()

# 05-monitoring-alerting/snowflake_monitoring.py
# This script creates set of functions/procedures to monitor snowflake
# SnowflakeMonitor - Check overall pipeline health
# check_snowpipe_lag - Check Snowpipe ingestion lag
# check_data_freshness - Check how fresh the data is
# check_failed_tasks - Check for failed Snowflake tasks
# check_credit_usage - Monitor Snowflake credit usage
# send_alert - Send alert via email while preventing duplicate alert within 1 hour
# generate_daily_report - Generate daily monitoring report
# This also schedules monitoring every 15 minutes



import snowflake.connector
import pandas as pd
import schedule
import time
import json
from datetime import datetime, timedelta
from email.mime.text import MIMEText
import smtplib

class SnowflakeMonitor:
    def __init__(self, config):
        self.conn = snowflake.connector.connect(**config)
        self.alerts_sent = {}
    
    def check_pipeline_health(self):
        """Check overall pipeline health"""
        checks = [
            self.check_snowpipe_lag,
            self.check_data_freshness,
            self.check_table_sizes,
            self.check_query_performance,
            self.check_failed_tasks,
            self.check_credit_usage
        ]
        
        results = {}
        for check in checks:
            try:
                results[check.__name__] = check()
            except Exception as e:
                results[check.__name__] = {'status': 'ERROR', 'error': str(e)}
        
        return results
    
    def check_snowpipe_lag(self):
        """Check Snowpipe ingestion lag"""
        query = """
        SELECT 
            PIPE_NAME,
            DATEDIFF('MINUTE', LAST_INGESTED, CURRENT_TIMESTAMP()) as LAG_MINUTES,
            PENDING_FILE_COUNT,
            STATE
        FROM INFORMATION_SCHEMA.PIPES
        WHERE PIPE_SCHEMA = 'RAW'
          AND PIPE_NAME LIKE 'TRADE_%';
        """
        
        df = pd.read_sql(query, self.conn)
        
        alerts = []
        for _, row in df.iterrows():
            if row['LAG_MINUTES'] > 30:  # More than 30 minutes lag
                alert = {
                    'severity': 'HIGH',
                    'pipe': row['PIPE_NAME'],
                    'lag_minutes': row['LAG_MINUTES'],
                    'pending_files': row['PENDING_FILE_COUNT'],
                    'message': f"Snowpipe {row['PIPE_NAME']} is lagging by {row['LAG_MINUTES']} minutes"
                }
                alerts.append(alert)
                self.send_alert(alert)
        
        return {
            'status': 'WARNING' if alerts else 'HEALTHY',
            'alerts': alerts,
            'summary': df.to_dict('records')
        }
    
    def check_data_freshness(self):
        """Check how fresh the data is"""
        query = """
        SELECT 
            TABLE_NAME,
            MAX(PROCESSED_AT) as LAST_UPDATE,
            DATEDIFF('MINUTE', MAX(PROCESSED_AT), CURRENT_TIMESTAMP()) as FRESHNESS_MINUTES
        FROM TRADE_DB.PROCESSED.VALID_TRADES
        WHERE DATE(PROCESSED_AT) >= CURRENT_DATE() - 1
        GROUP BY TABLE_NAME;
        """
        
        df = pd.read_sql(query, self.conn)
        
        stale_tables = df[df['FRESHNESS_MINUTES'] > 60]
        if not stale_tables.empty:
            for _, row in stale_tables.iterrows():
                alert = {
                    'severity': 'MEDIUM',
                    'table': row['TABLE_NAME'],
                    'last_update': row['LAST_UPDATE'],
                    'stale_minutes': row['FRESHNESS_MINUTES'],
                    'message': f"Table {row['TABLE_NAME']} hasn't been updated in {row['FRESHNESS_MINUTES']} minutes"
                }
                self.send_alert(alert)
        
        return {
            'status': 'HEALTHY' if stale_tables.empty else 'WARNING',
            'freshness_data': df.to_dict('records')
        }
    
    def check_failed_tasks(self):
        """Check for failed Snowflake tasks"""
        query = """
        SELECT 
            NAME as TASK_NAME,
            DATABASE_NAME,
            SCHEMA_NAME,
            STATE,
            ERROR_CODE,
            ERROR_MESSAGE,
            SCHEDULED_TIME,
            COMPLETED_TIME
        FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
        WHERE DATABASE_NAME = 'TRADE_DB'
          AND STATE = 'FAILED'
          AND SCHEDULED_TIME >= DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
        ORDER BY SCHEDULED_TIME DESC;
        """
        
        df = pd.read_sql(query, self.conn)
        
        if not df.empty:
            for _, row in df.iterrows():
                alert = {
                    'severity': 'HIGH',
                    'task': row['TASK_NAME'],
                    'error_code': row['ERROR_CODE'],
                    'error_message': row['ERROR_MESSAGE'],
                    'message': f"Task {row['TASK_NAME']} failed with error: {row['ERROR_MESSAGE']}"
                }
                self.send_alert(alert)
        
        return {
            'status': 'HEALTHY' if df.empty else 'CRITICAL',
            'failed_tasks': df.to_dict('records')
        }
    
    def check_credit_usage(self):
        """Monitor Snowflake credit usage"""
        query = """
        SELECT 
            WAREHOUSE_NAME,
            SUM(CREDITS_USED) as TOTAL_CREDITS,
            SUM(CREDITS_USED_COMPUTE) as COMPUTE_CREDITS,
            SUM(CREDITS_USED_CLOUD_SERVICES) as CLOUD_SERVICES_CREDITS,
            AVG(AVG_RUNNING) as AVG_CONCURRENT_QUERIES
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
          AND WAREHOUSE_NAME LIKE 'TRADE_%'
        GROUP BY WAREHOUSE_NAME
        ORDER BY TOTAL_CREDITS DESC;
        """
        
        df = pd.read_sql(query, self.conn)
        
        # Check for abnormal usage
        threshold_multiplier = 2
        avg_usage = df['TOTAL_CREDITS'].mean()
        
        high_usage = df[df['TOTAL_CREDITS'] > avg_usage * threshold_multiplier]
        
        if not high_usage.empty:
            for _, row in high_usage.iterrows():
                alert = {
                    'severity': 'MEDIUM',
                    'warehouse': row['WAREHOUSE_NAME'],
                    'credits_used': row['TOTAL_CREDITS'],
                    'avg_concurrent': row['AVG_CONCURRENT_QUERIES'],
                    'message': f"Warehouse {row['WAREHOUSE_NAME']} using {row['TOTAL_CREDITS']} credits (above threshold)"
                }
                self.send_alert(alert)
        
        return {
            'status': 'HEALTHY' if high_usage.empty else 'WARNING',
            'credit_usage': df.to_dict('records'),
            'summary': {
                'total_credits': df['TOTAL_CREDITS'].sum(),
                'warehouses': len(df)
            }
        }
    
    def send_alert(self, alert_data):
        """Send alert via email/Slack/Webhook"""
        alert_key = f"{alert_data.get('severity')}_{alert_data.get('task', '')}_{alert_data.get('table', '')}"
        
        # Prevent duplicate alerts within 1 hour
        if alert_key in self.alerts_sent:
            last_sent = self.alerts_sent[alert_key]
            if datetime.now() - last_sent < timedelta(hours=1):
                return
        
        # Send email alert
        msg = MIMEText(json.dumps(alert_data, indent=2))
        msg['Subject'] = f"[{alert_data['severity']}] Snowflake Alert: {alert_data.get('message', '')[:50]}"
        msg['From'] = 'snowflake-alerts@company.com'
        msg['To'] = 'data-engineering@company.com'
        
        try:
            with smtplib.SMTP('smtp.company.com') as server:
                server.send_message(msg)
            print(f"Alert sent: {alert_data['message']}")
            self.alerts_sent[alert_key] = datetime.now()
        except Exception as e:
            print(f"Failed to send alert: {e}")
    
    def generate_daily_report(self):
        """Generate daily monitoring report"""
        health_checks = self.check_pipeline_health()
        
        report = {
            'date': datetime.now().isoformat(),
            'overall_status': 'HEALTHY',
            'checks': health_checks,
            'summary': {
                'alerts_today': len(self.alerts_sent),
                'credit_usage_today': self.get_daily_credits(),
                'data_volume': self.get_data_volume(),
            }
        }
        
        # Save report to Snowflake
        df = pd.DataFrame([report])
        df.to_sql('MONITORING_REPORTS', self.conn, 
                  schema='AUDIT', if_exists='append', index=False)
        
        return report

# Schedule monitoring
if __name__ == "__main__":
    config = {
        'user': os.environ['SNOWFLAKE_USER'],
        'password': os.environ['SNOWFLAKE_PASSWORD'],
        'account': os.environ['SNOWFLAKE_ACCOUNT'],
        'warehouse': 'TRADE_ANALYTICS_WH',
        'database': 'TRADE_DB',
        'schema': 'AUDIT',
        'role': 'TRADE_ADMIN'
    }
    
    monitor = SnowflakeMonitor(config)
    
    # Schedule checks
    schedule.every(15).minutes.do(monitor.check_pipeline_health)
    schedule.every().hour.do(monitor.check_snowpipe_lag)
    schedule.every().day.at("08:00").do(monitor.generate_daily_report)
    
    while True:
        schedule.run_pending()
        time.sleep(60)

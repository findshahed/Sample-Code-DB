# airflow_dags/trade_pipeline_dag.py
# Airflow DAG for orchestrating the trade processing pipeline
# get_environment_config - Get environment configuration
# check_data_quality - Check data quality and decide next step
# generate_daily_report - Generate daily trade report
# check_pipeline_health - Check overall pipeline health
# and finally define task dependancy
"""
Airflow DAG for orchestrating the trade processing pipeline
"""
from datetime import datetime, timedelta
from typing import Dict, List, Optional

from airflow import DAG
from airflow.providers.google.cloud.operators.dataflow import DataflowStartFlexTemplateOperator
from airflow.providers.google.cloud.sensors.dataflow import DataflowJobStatusSensor
from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.operators.python import PythonOperator, BranchPythonOperator
from airflow.operators.dummy import DummyOperator
from airflow.operators.email import EmailOperator
from airflow.utils.trigger_rule import TriggerRule
from airflow.models import Variable

from operators.snowflake_operator import SnowflakeStoredProcedureOperator
from sensors.snowflake_sensor import SnowflakeTableSensor


default_args = {
    'owner': 'trade_team',
    'depends_on_past': False,
    'email': ['data-engineering@company.com'],
    'email_on_failure': True,
    'email_on_retry': False,
    'retries': 3,
    'retry_delay': timedelta(minutes=5),
    'start_date': datetime(2024, 1, 1),
}


def get_environment_config() -> Dict:
    """Get environment configuration"""
    env = Variable.get("environment", default_var="dev")
    
    configs = {
        "dev": {
            "project_id": "trade-dev-project",
            "region": "us-central1",
            "snowflake_env_suffix": "_DEV",
            "dataflow_template": "gs://trade-dev-templates/trade-processing.json",
            "alert_threshold": 1000,
        },
        "staging": {
            "project_id": "trade-staging-project",
            "region": "us-central1",
            "snowflake_env_suffix": "_STAGING",
            "dataflow_template": "gs://trade-staging-templates/trade-processing.json",
            "alert_threshold": 5000,
        },
        "prod": {
            "project_id": "trade-prod-project",
            "region": "us-central1",
            "snowflake_env_suffix": "",
            "dataflow_template": "gs://trade-prod-templates/trade-processing.json",
            "alert_threshold": 10000,
        }
    }
    
    return configs.get(env, configs["dev"])


def check_data_quality(**context) -> str:
    """Check data quality and decide next step"""
    ti = context['ti']
    
    # Get data quality metrics from Snowflake
    snowflake_hook = SnowflakeHook(snowflake_conn_id='snowflake_default')
    
    query = """
    SELECT 
        COUNT(*) as total_trades,
        COUNT(CASE WHEN STATUS = 'REJECTED' THEN 1 END) as rejected_trades,
        COUNT(CASE WHEN STATUS = 'ERROR' THEN 1 END) as error_trades
    FROM TRADE_DB.PROCESSED.VALID_TRADES
    WHERE DATE(PROCESSED_AT) = CURRENT_DATE()
    """
    
    result = snowflake_hook.get_first(query)
    
    if result:
        total, rejected, errors = result
        rejection_rate = (rejected / total) * 100 if total > 0 else 0
        
        # Push metrics to XCom
        ti.xcom_push(key='data_quality_metrics', value={
            'total_trades': total,
            'rejected_trades': rejected,
            'error_trades': errors,
            'rejection_rate': rejection_rate
        })
        
        # Decide next step based on rejection rate
        config = get_environment_config()
        if rejection_rate > 5:  # More than 5% rejection rate
            return 'investigate_data_quality_issues'
        elif errors > 10:  # More than 10 errors
            return 'handle_processing_errors'
    
    return 'proceed_with_normal_processing'


def generate_daily_report(**context):
    """Generate daily trade report"""
    ti = context['ti']
    execution_date = context['execution_date']
    
    snowflake_hook = SnowflakeHook(snowflake_conn_id='snowflake_default')
    
    # Generate report
    report_query = f"""
    CALL TRADE_DB.ANALYTICS.GENERATE_DAILY_REPORT(
        '{execution_date.strftime("%Y-%m-%d")}',
        'DAILY_TRADE_REPORT_{execution_date.strftime("%Y%m%d")}'
    )
    """
    
    try:
        snowflake_hook.run(report_query)
        ti.xcom_push(key='report_generated', value=True)
    except Exception as e:
        ti.xcom_push(key='report_generated', value=False)
        raise


def check_pipeline_health(**context):
    """Check overall pipeline health"""
    ti = context['ti']
    
    snowflake_hook = SnowflakeHook(snowflake_conn_id='snowflake_default')
    
    health_checks = [
        {
            'name': 'snowpipe_lag',
            'query': """
                SELECT DATEDIFF('MINUTE', LAST_INGESTED, CURRENT_TIMESTAMP()) as lag_minutes
                FROM INFORMATION_SCHEMA.PIPES
                WHERE PIPE_NAME = 'TRADE_PIPE'
            """,
            'threshold': 30  # minutes
        },
        {
            'name': 'data_freshness',
            'query': """
                SELECT DATEDIFF('MINUTE', MAX(PROCESSED_AT), CURRENT_TIMESTAMP()) as freshness_minutes
                FROM TRADE_DB.PROCESSED.VALID_TRADES
            """,
            'threshold': 60  # minutes
        },
        {
            'name': 'queue_backlog',
            'query': """
                SELECT COUNT(*) as pending_count
                FROM TRADE_DB.RAW.TRADES_STAGING
                WHERE PROCESSED = FALSE
            """,
            'threshold': 1000
        }
    ]
    
    health_status = {}
    
    for check in health_checks:
        try:
            result = snowflake_hook.get_first(check['query'])
            if result:
                value = result[0] if isinstance(result, tuple) else result
                health_status[check['name']] = {
                    'value': value,
                    'healthy': value <= check['threshold'],
                    'threshold': check['threshold']
                }
        except Exception as e:
            health_status[check['name']] = {
                'value': None,
                'healthy': False,
                'error': str(e)
            }
    
    ti.xcom_push(key='pipeline_health', value=health_status)
    
    # Check if all health checks passed
    all_healthy = all(status.get('healthy', False) for status in health_status.values())
    return all_healthy


# Create DAG
with DAG(
    dag_id='trade_processing_pipeline',
    default_args=default_args,
    description='End-to-end trade processing pipeline',
    schedule_interval='@daily',
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=['trade', 'data-pipeline', 'gcp', 'snowflake'],
) as dag:
    
    config = get_environment_config()
    
    start = DummyOperator(task_id='start')
    
    # Initialize Snowflake environment
    init_snowflake = SnowflakeOperator(
        task_id='initialize_snowflake',
        sql=f"""
        USE WAREHOUSE TRADE_LOAD_WH{config['snowflake_env_suffix']};
        USE DATABASE TRADE_DB{config['snowflake_env_suffix']};
        USE SCHEMA PROCESSED;
        
        -- Create daily partition
        CALL CREATE_DAILY_PARTITION('{{ ds }}');
        """,
        snowflake_conn_id='snowflake_default',
    )
    
    # Start Dataflow pipeline
    start_dataflow = DataflowStartFlexTemplateOperator(
        task_id='start_dataflow_pipeline',
        project_id=config['project_id'],
        location=config['region'],
        body={
            'launchParameter': {
                'jobName': f"trade-processing-{{{{ ds_nodash }}}}",
                'containerSpecGcsPath': config['dataflow_template'],
                'parameters': {
                    'inputSubscription': f"projects/{config['project_id']}/subscriptions/trades-sub",
                    'outputTable': f"{config['project_id']}:TRADE_DB.VALID_TRADES",
                    'rejectedTable': f"{config['project_id']}:TRADE_DB.REJECTED_TRADES",
                    'environment': "{{ var.value.environment }}",
                },
                'environment': {
                    'tempLocation': f"gs://{config['project_id']}-temp/temp",
                    'network': 'default',
                    'subnetwork': 'regions/us-central1/subnetworks/default',
                    'enableStreamingEngine': True,
                }
            }
        },
    )
    
    # Monitor Dataflow job
    monitor_dataflow = DataflowJobStatusSensor(
        task_id='monitor_dataflow_job',
        job_id="{{ task_instance.xcom_pull(task_ids='start_dataflow_pipeline')['id'] }}",
        project_id=config['project_id'],
        location=config['region'],
        expected_statuses={'JOB_STATE_RUNNING'},
        timeout=3600,
        poke_interval=60,
    )
    
    # Run Snowflake tasks
    run_snowflake_tasks = SnowflakeStoredProcedureOperator(
        task_id='run_snowflake_tasks',
        procedure_name='PROCESS_NEW_TRADES',
        database=f"TRADE_DB{config['snowflake_env_suffix']}",
        schema='PROCESSED',
        snowflake_conn_id='snowflake_default',
    )
    
    # Wait for data to be processed
    wait_for_data = SnowflakeTableSensor(
        task_id='wait_for_data_processing',
        table_name=f"TRADE_DB{config['snowflake_env_suffix']}.PROCESSED.VALID_TRADES",
        target_date="{{ ds }}",
        min_count=1,
        timeout=1800,
        poke_interval=30,
        snowflake_conn_id='snowflake_default',
    )
    
    # Check data quality
    check_quality = BranchPythonOperator(
        task_id='check_data_quality',
        python_callable=check_data_quality,
    )
    
    # Data quality investigation
    investigate_quality = SnowflakeOperator(
        task_id='investigate_data_quality_issues',
        sql="""
        SELECT 
            REJECTION_REASON,
            COUNT(*) as count,
            ARRAY_AGG(DISTINCT TRADE_ID) as sample_trades
        FROM TRADE_DB.AUDIT.REJECTED_TRADES
        WHERE DATE(REJECTED_AT) = '{{ ds }}'
        GROUP BY REJECTION_REASON
        ORDER BY count DESC
        LIMIT 10;
        """,
        snowflake_conn_id='snowflake_default',
    )
    
    # Handle processing errors
    handle_errors = SnowflakeOperator(
        task_id='handle_processing_errors',
        sql="""
        UPDATE TRADE_DB.PROCESSED.VALID_TRADES
        SET STATUS = 'REPROCESS'
        WHERE STATUS = 'ERROR'
        AND DATE(PROCESSED_AT) = '{{ ds }}';
        
        INSERT INTO TRADE_DB.AUDIT.PROCESSING_ERRORS
        SELECT 
            '{{ ds }}' as ERROR_DATE,
            TRADE_ID,
            ERROR_MESSAGE,
            CURRENT_TIMESTAMP() as LOGGED_AT
        FROM TRADE_DB.PROCESSED.VALID_TRADES
        WHERE STATUS = 'ERROR'
        AND DATE(PROCESSED_AT) = '{{ ds }}';
        """,
        snowflake_conn_id='snowflake_default',
    )
    
    # Normal processing path
    proceed_normal = DummyOperator(task_id='proceed_with_normal_processing')
    
    # Generate reports
    generate_report = PythonOperator(
        task_id='generate_daily_report',
        python_callable=generate_daily_report,
    )
    
    # Check pipeline health
    health_check = PythonOperator(
        task_id='check_pipeline_health',
        python_callable=check_pipeline_health,
    )
    
    # Send success notification
    send_success = EmailOperator(
        task_id='send_success_notification',
        to='trade-ops@company.com',
        subject='Trade Pipeline Success - {{ ds }}',
        html_content="""
        <h3>Trade Processing Pipeline Completed Successfully</h3>
        <p>Date: {{ ds }}</p>
        <p>All tasks completed without errors.</p>
        <p><a href="https://console.cloud.google.com/dataflow">View Dataflow Jobs</a></p>
        <p><a href="https://app.snowflake.com">View Snowflake Data</a></p>
        """,
        trigger_rule=TriggerRule.ALL_SUCCESS,
    )
    
    # Send failure alert
    send_failure = EmailOperator(
        task_id='send_failure_alert',
        to=['data-engineering@company.com', 'trade-ops@company.com'],
        subject='ALERT: Trade Pipeline Failed - {{ ds }}',
        html_content="""
        <h3>Trade Processing Pipeline Failed</h3>
        <p>Date: {{ ds }}</p>
        <p>Failed task: {{ task_instance.task_id }}</p>
        <p>Please check the Airflow logs for details.</p>
        """,
        trigger_rule=TriggerRule.ONE_FAILED,
    )
    
    end = DummyOperator(
        task_id='end',
        trigger_rule=TriggerRule.ALL_DONE
    )
    
    # Define task dependencies
    start >> init_snowflake >> start_dataflow >> monitor_dataflow
    monitor_dataflow >> run_snowflake_tasks >> wait_for_data >> check_quality
    
    check_quality >> [investigate_quality, handle_errors, proceed_normal]
    investigate_quality >> generate_report
    handle_errors >> generate_report
    proceed_normal >> generate_report
    
    generate_report >> health_check >> send_success >> end
    
    # Failure path
    [start_dataflow, monitor_dataflow, run_snowflake_tasks, wait_for_data,
     check_quality, generate_report, health_check] >> send_failure >> end

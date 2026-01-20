# 04-orchestration/dags/trade_streaming_dag.py
# Following script creates Airflow DAGs with snowflake operators
# End-to-end trade processing pipeline with Snowflake
# with this DAG, snowflake stream pipeline is started, snowflake transformers are executed, data quality checks performed, Daily report generated and successful notification is generated
# In case of failures, failure notification is generated via email
# Dependancies of DAGs are also defined in this script
#
from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.providers.google.cloud.operators.dataflow import DataflowStartFlexTemplateOperator
from airflow.operators.python import PythonOperator
from airflow.operators.email import EmailOperator
from airflow.sensors.external_task import ExternalTaskSensor

default_args = {
    'owner': 'trade_team',
    'depends_on_past': False,
    'email': ['data-engineering@company.com'],
    'email_on_failure': True,
    'email_on_retry': False,
    'retries': 3,
    'retry_delay': timedelta(minutes=5),
    'snowflake_conn_id': 'snowflake_default',
}

with DAG(
    'trade_processing_pipeline',
    default_args=default_args,
    description='End-to-end trade processing pipeline with Snowflake',
    schedule_interval='@daily',
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=['trade', 'snowflake', 'gcp'],
) as dag:
    
    # Wait for upstream data availability
    wait_for_data = ExternalTaskSensor(
        task_id='wait_for_source_data',
        external_dag_id='data_extraction_dag',
        external_task_id='extract_complete',
        allowed_states=['success'],
        failed_states=['failed'],
        mode='reschedule',
        timeout=7200,
    )
    
    # Initialize Snowflake environment
    init_snowflake = SnowflakeOperator(
        task_id='initialize_snowflake',
        sql='''
        USE WAREHOUSE TRADE_LOAD_WH;
        USE DATABASE TRADE_DB;
        USE SCHEMA PROCESSED;
        
        -- Create daily partition
        CALL TRADE_DB.PROCESSED.CREATE_DAILY_PARTITION('{{ ds }}');
        ''',
        autocommit=True,
    )
    
    # Start streaming pipeline
    start_streaming = DataflowStartFlexTemplateOperator(
        task_id='start_streaming_pipeline',
        project_id='{{ var.value.gcp_project }}',
        location='us-central1',
        body={
            'launchParameter': {
                'jobName': 'trade-streaming-{{ ds_nodash }}',
                'containerSpecGcsPath': '{{ var.value.dataflow_template }}',
                'parameters': {
                    'inputTopic': 'projects/{{ var.value.gcp_project }}/topics/trades',
                    'snowflakeAccount': '{{ var.value.snowflake_account }}',
                    'snowflakeUser': '{{ var.value.snowflake_user }}',
                    'snowflakePassword': '{{ var.value.snowflake_password }}',
                    'snowflakeDatabase': 'TRADE_DB',
                    'snowflakeSchema': 'PROCESSED',
                    'outputTable': 'VALID_TRADES',
                    'rejectedTable': 'REJECTED_TRADES',
                    'startDate': '{{ ds }}',
                    'endDate': '{{ ds }}',
                },
                'environment': {
                    'tempLocation': 'gs://{{ var.value.gcp_project }}-temp/temp',
                    'network': 'default',
                    'subnetwork': 'regions/us-central1/subnetworks/default',
                    'enableStreamingEngine': True,
                }
            }
        },
    )
    
    # Run Snowflake transformations
    run_snowflake_tasks = SnowflakeOperator(
        task_id='run_snowflake_transformations',
        sql='''
        -- Execute all scheduled tasks
        EXECUTE TASK TRADE_DB.PROCESSED.PROCESS_NEW_TRADES;
        
        -- Wait for completion
        CALL SYSTEM$WAIT(60);
        
        EXECUTE TASK TRADE_DB.AUDIT.RUN_DATA_QUALITY_CHECKS;
        
        -- Refresh materialized views
        ALTER MATERIALIZED VIEW TRADE_DB.ANALYTICS.DAILY_TRADE_SUMMARY REFRESH;
        ALTER MATERIALIZED VIEW TRADE_DB.ANALYTICS.COUNTERPARTY_RISK REFRESH;
        ''',
        autocommit=True,
    )
    
    # Data quality checks
    data_quality_check = SnowflakeOperator(
        task_id='run_data_quality_checks',
        sql='''
        WITH quality_issues AS (
            SELECT 
                COUNT(*) as total_issues,
                STRING_AGG(DISTINCT ISSUE_TYPE, ', ') as issue_types
            FROM TRADE_DB.AUDIT.DATA_QUALITY_ISSUES
            WHERE DATE(CHECK_TIMESTAMP) = '{{ ds }}'
        )
        SELECT 
            CASE 
                WHEN total_issues > 100 THEN 'FAIL'
                WHEN total_issues > 50 THEN 'WARN'
                ELSE 'PASS'
            END as quality_status,
            total_issues,
            issue_types
        FROM quality_issues;
        ''',
        do_xcom_push=True,
    )
    
    def evaluate_quality(**context):
        """Evaluate data quality results"""
        ti = context['ti']
        result = ti.xcom_pull(task_ids='run_data_quality_checks')
        
        if result and result[0][0] == 'FAIL':
            raise ValueError(f"Data quality check failed: {result[0]}")
        elif result and result[0][0] == 'WARN':
            print(f"Data quality warning: {result[0]}")
    
    evaluate_quality_task = PythonOperator(
        task_id='evaluate_quality',
        python_callable=evaluate_quality,
        provide_context=True,
    )
    
    # Generate daily report
    generate_report = SnowflakeOperator(
        task_id='generate_daily_report',
        sql='''
        CALL TRADE_DB.ANALYTICS.GENERATE_DAILY_REPORT(
            '{{ ds }}',
            'DAILY_TRADE_REPORT_{{ ds_nodash }}'
        );
        
        -- Export report to GCS
        COPY INTO @TRADE_DB.ANALYTICS.reports_stage/daily_reports/
        FROM (
            SELECT * 
            FROM TRADE_DB.ANALYTICS.DAILY_TRADE_REPORT_{{ ds_nodash }}
        )
        FILE_FORMAT = (TYPE = CSV, COMPRESSION = GZIP)
        OVERWRITE = TRUE
        HEADER = TRUE;
        ''',
        autocommit=True,
    )
    
    # Send success notification
    send_success_notification = EmailOperator(
        task_id='send_success_notification',
        to='trade-ops@company.com',
        subject='Trade Pipeline Success - {{ ds }}',
        html_content='''
        <h3>Trade Processing Pipeline Completed Successfully</h3>
        <p>Date: {{ ds }}</p>
        <p>All tasks completed without errors.</p>
        <p>Summary:</p>
        <ul>
            <li>Streaming pipeline: Running</li>
            <li>Snowflake transformations: Complete</li>
            <li>Data quality: Passed</li>
            <li>Daily report: Generated</li>
        </ul>
        ''',
        trigger_rule='all_success',
    )
    
    # Send failure alert
    send_failure_alert = EmailOperator(
        task_id='send_failure_alert',
        to=['data-engineering@company.com', 'trade-ops@company.com'],
        subject='ALERT: Trade Pipeline Failed - {{ ds }}',
        html_content='''
        <h3>Trade Processing Pipeline Failed</h3>
        <p>Date: {{ ds }}</p>
        <p>Please check Airflow logs for details.</p>
        <p>Failed task: {{ task_instance.task_id }}</p>
        ''',
        trigger_rule='one_failed',
    )
    
    # Define dependencies
    wait_for_data >> init_snowflake
    init_snowflake >> start_streaming
    start_streaming >> run_snowflake_tasks
    run_snowflake_tasks >> data_quality_check
    data_quality_check >> evaluate_quality_task
    evaluate_quality_task >> generate_report
    generate_report >> send_success_notification
    
    # Failure path
    [start_streaming, run_snowflake_tasks, data_quality_check, 
     evaluate_quality_task, generate_report] >> send_failure_alert

# 03-snowflake-integration/snowpipe/setup_snowpipe.py
import snowflake.connector
import json
from google.cloud import storage

class SnowpipeManager:
    def __init__(self, snowflake_config):
        self.conn = snowflake.connector.connect(**snowflake_config)
        self.stage_name = 'TRADE_DB.RAW.TRADE_STAGE'
        self.pipe_name = 'TRADE_DB.RAW.TRADE_PIPE'
    
    def create_external_stage(self, gcs_bucket, service_account_key):
        """Create external stage pointing to GCS"""
        sql = f"""
        CREATE OR REPLACE STAGE {self.stage_name}
        URL = 'gcs://{gcs_bucket}/trades/'
        STORAGE_INTEGRATION = gcs_int
        FILE_FORMAT = (
            TYPE = 'JSON'
            STRIP_OUTER_ARRAY = TRUE
            ALLOW_DUPLICATE = TRUE
        )
        COMMENT = 'GCS stage for trade data';
        """
        
        self.conn.cursor().execute(sql)
        print(f"Created stage: {self.stage_name}")
    
    def create_snowpipe(self, notification_channel=None):
        """Create Snowpipe for automatic ingestion"""
        sql = f"""
        CREATE OR REPLACE PIPE {self.pipe_name}
        AUTO_INGEST = TRUE
        INTEGRATION = 'GCS_NOTIFICATION'
        AS
        COPY INTO TRADE_DB.RAW.TRADES_STAGING (RAW_DATA, FILE_NAME, SOURCE_SYSTEM, BATCH_ID)
        FROM (
            SELECT 
                $1,
                METADATA$FILENAME,
                'GCP_PUBSUB',
                SPLIT_PART(METADATA$FILENAME, '/', -2)
            FROM @{self.stage_name}
        )
        FILE_FORMAT = (
            TYPE = 'JSON'
            STRIP_OUTER_ARRAY = TRUE
        )
        ON_ERROR = 'CONTINUE';
        """
        
        self.conn.cursor().execute(sql)
        print(f"Created pipe: {self.pipe_name}")
        
        if notification_channel:
            self.configure_notification(notification_channel)
    
    def configure_notification(self, notification_channel):
        """Configure GCS notification for Snowpipe"""
        from google.cloud import pubsub_v1
        
        publisher = pubsub_v1.PublisherClient()
        topic_path = publisher.topic_path(
            notification_channel['project_id'],
            notification_channel['topic_name']
        )
        
        # Create notification configuration
        storage_client = storage.Client()
        bucket = storage_client.bucket(notification_channel['bucket_name'])
        
        notification = bucket.notification(
            topic_path,
            topic_project=notification_channel['project_id'],
            event_types=['OBJECT_FINALIZE'],
            blob_name_prefix='trades/'
        )
        
        notification.create()
        print(f"Configured GCS notification for bucket: {notification_channel['bucket_name']}")
    
    def monitor_snowpipe(self):
        """Monitor Snowpipe ingestion status"""
        sql = f"""
        SELECT 
            PIPE_NAME,
            LAST_INGESTED,
            CURRENT_OFFSET,
            STATE,
            ERROR_COUNT,
            LAST_ERROR_MESSAGE,
            PENDING_FILE_COUNT
        FROM INFORMATION_SCHEMA.PIPES
        WHERE PIPE_NAME = '{self.pipe_name.split('.')[-1]}';
        """
        
        cursor = self.conn.cursor()
        cursor.execute(sql)
        results = cursor.fetchall()
        
        for row in results:
            print(f"Pipe: {row[0]}, State: {row[3]}, Pending: {row[6]}")
        
        return results
    
    def refresh_pipe(self):
        """Manually refresh Snowpipe"""
        sql = f"ALTER PIPE {self.pipe_name} REFRESH;"
        self.conn.cursor().execute(sql)
        print("Snowpipe refreshed")

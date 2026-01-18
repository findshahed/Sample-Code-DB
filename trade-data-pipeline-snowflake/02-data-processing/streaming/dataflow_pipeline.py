# 02-data-processing/streaming/dataflow_pipeline.py
import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, StandardOptions
from apache_beam.transforms.window import FixedWindows
from apache_beam.io.gcp.bigquery import WriteToBigQuery
from snowflake_writer import SnowflakeWriter
import json
import datetime
import logging
from validation_logic import TradeValidator

class ProcessTradeDoFn(beam.DoFn):
    """Process individual trade with validation"""
    
    def __init__(self, snowflake_config):
        self.snowflake_config = snowflake_config
        self.validator = TradeValidator()
        self.batch_size = 1000
        self.batch = []
        
    def setup(self):
        """Initialize Snowflake connection pool"""
        import snowflake.connector
        self.conn_pool = []
        for _ in range(5):  # Connection pool
            conn = snowflake.connector.connect(
                user=self.snowflake_config['user'],
                password=self.snowflake_config['password'],
                account=self.snowflake_config['account'],
                warehouse=self.snowflake_config['warehouse'],
                database=self.snowflake_config['database'],
                schema=self.snowflake_config['schema'],
                role=self.snowflake_config['role']
            )
            self.conn_pool.append(conn)
    
    def process(self, element, window=beam.DoFn.WindowParam):
        """Process trade message"""
        try:
            trade = json.loads(element.decode('utf-8'))
            trade_id = trade.get('trade_id')
            
            # Get existing version from Snowflake
            existing_version = self.get_existing_version(trade_id)
            
            # Validate trade
            is_valid, reason, details = self.validator.validate_trade(
                trade, existing_version)
            
            # Add metadata
            trade['processed_at'] = datetime.datetime.utcnow().isoformat()
            trade['window_start'] = window.start.to_utc_datetime().isoformat()
            trade['window_end'] = window.end.to_utc_datetime().isoformat()
            trade['pipeline_run_id'] = getattr(self, 'pipeline_run_id', 'unknown')
            
            if is_valid:
                if reason == 'EXPIRED':
                    trade['status'] = 'EXPIRED'
                    self.add_to_batch('expired_trades', trade)
                else:
                    trade['status'] = 'VALID'
                    self.add_to_batch('valid_trades', trade)
            else:
                trade['rejection_reason'] = reason
                trade['rejection_details'] = details
                trade['status'] = 'REJECTED'
                self.add_to_batch('rejected_trades', trade)
                
            # Flush batch if size limit reached
            if len(self.batch) >= self.batch_size:
                self.flush_batch()
                
        except Exception as e:
            logging.error(f"Error processing trade: {e}")
            error_record = {
                'error': str(e),
                'raw_data': element.decode('utf-8'),
                'processed_at': datetime.datetime.utcnow().isoformat()
            }
            yield beam.pvalue.TaggedOutput('error_trades', error_record)
    
    def get_existing_version(self, trade_id):
        """Check existing version in Snowflake"""
        conn = self.conn_pool[0]  # Get from pool
        try:
            cursor = conn.cursor()
            query = """
                SELECT MAX(version) 
                FROM TRADE_DB.PROCESSED.VALID_TRADES 
                WHERE TRADE_ID = %s AND IS_CURRENT = TRUE
            """
            cursor.execute(query, (trade_id,))
            result = cursor.fetchone()
            return result[0] if result[0] is not None else None
        except Exception as e:
            logging.error(f"Error checking existing version: {e}")
            return None
    
    def add_to_batch(self, table_name, record):
        """Add record to batch for bulk insert"""
        self.batch.append({
            'table': table_name,
            'record': record
        })
    
    def flush_batch(self):
        """Flush batch to Snowflake"""
        if not self.batch:
            return
        
        # Group by table
        grouped = {}
        for item in self.batch:
            table = item['table']
            if table not in grouped:
                grouped[table] = []
            grouped[table].append(item['record'])
        
        # Insert to each table
        for table, records in grouped.items():
            self.bulk_insert_to_snowflake(table, records)
        
        self.batch = []
    
    def bulk_insert_to_snowflake(self, table_name, records):
        """Bulk insert records to Snowflake"""
        from snowflake.connector.pandas_tools import write_pandas
        import pandas as pd
        
        df = pd.DataFrame(records)
        conn = self.conn_pool[1]  # Use different connection
        
        if table_name == 'valid_trades':
            schema = 'TRADE_DB.PROCESSED'
            success, nchunks, nrows, _ = write_pandas(
                conn, df, 'VALID_TRADES', 
                database='TRADE_DB', 
                schema='PROCESSED',
                chunk_size=10000
            )
        elif table_name == 'rejected_trades':
            success, nchunks, nrows, _ = write_pandas(
                conn, df, 'REJECTED_TRADES',
                database='TRADE_DB',
                schema='AUDIT',
                chunk_size=10000
            )
        elif table_name == 'expired_trades':
            success, nchunks, nrows, _ = write_pandas(
                conn, df, 'EXPIRED_TRADES',
                database='TRADE_DB',
                schema='PROCESSED',
                chunk_size=10000
            )
        
        logging.info(f"Inserted {nrows} rows into {table_name}")
    
    def teardown(self):
        """Cleanup connections"""
        for conn in self.conn_pool:
            try:
                conn.close()
            except:
                pass
        self.flush_batch()  # Flush any remaining records

class WriteToSnowflake(beam.PTransform):
    """Custom PTransform for writing to Snowflake"""
    
    def __init__(self, snowflake_config, table_name):
        self.snowflake_config = snowflake_config
        self.table_name = table_name
    
    def expand(self, pcoll):
        return (
            pcoll
            | f'Batch for {self.table_name}' >> beam.BatchElements(
                min_batch_size=100, 
                max_batch_size=10000
            )
            | f'Write to {self.table_name}' >> beam.ParDo(
                SnowflakeWriter(self.snowflake_config, self.table_name)
            )
        )

def run_streaming_pipeline():
    """Main pipeline execution"""
    
    # Pipeline options
    options = PipelineOptions(
        runner='DataflowRunner',
        project='your-gcp-project',
        region='us-central1',
        streaming=True,
        save_main_session=True,
        setup_file='./setup.py',
        temp_location='gs://your-bucket/temp',
        staging_location='gs://your-bucket/staging',
    )
    
    # Snowflake configuration
    snowflake_config = {
        'account': os.environ['SNOWFLAKE_ACCOUNT'],
        'user': os.environ['SNOWFLAKE_USER'],
        'password': os.environ['SNOWFLAKE_PASSWORD'],
        'warehouse': 'TRADE_LOAD_WH',
        'database': 'TRADE_DB',
        'schema': 'PROCESSED',
        'role': 'TRADE_LOADER'
    }
    
    with beam.Pipeline(options=options) as pipeline:
        # Read from Pub/Sub
        messages = (
            pipeline
            | 'Read from PubSub' >> beam.io.ReadFromPubSub(
                topic='projects/your-project/topics/trades-topic',
                timestamp_attribute='publish_time'
            )
            | 'Window into 1 minute batches' >> beam.WindowInto(
                FixedWindows(60)  # 1-minute windows
            )
        )
        
        # Process trades
        processed = (
            messages
            | 'Parse JSON' >> beam.Map(lambda x: json.loads(x.decode('utf-8')))
            | 'Process and Validate' >> beam.ParDo(
                ProcessTradeDoFn(snowflake_config)
            ).with_outputs('error_trades', main='processed_trades')
        )
        
        # Write valid trades to Snowflake
        valid_trades = (
            processed.processed_trades
            | 'Filter Valid Trades' >> beam.Filter(
                lambda x: x.get('status') == 'VALID'
            )
            | 'Write Valid to Snowflake' >> WriteToSnowflake(
                snowflake_config, 'VALID_TRADES'
            )
        )
        
        # Write rejected trades to Snowflake
        rejected_trades = (
            processed.processed_trades
            | 'Filter Rejected Trades' >> beam.Filter(
                lambda x: x.get('status') == 'REJECTED'
            )
            | 'Write Rejected to Snowflake' >> WriteToSnowflake(
                snowflake_config, 'REJECTED_TRADES'
            )
        )
        
        # Write expired trades to Snowflake
        expired_trades = (
            processed.processed_trades
            | 'Filter Expired Trades' >> beam.Filter(
                lambda x: x.get('status') == 'EXPIRED'
            )
            | 'Write Expired to Snowflake' >> WriteToSnowflake(
                snowflake_config, 'EXPIRED_TRADES'
            )
        )
        
        # Write errors to BigQuery for monitoring
        _ = (
            processed.error_trades
            | 'Write Errors to BigQuery' >> WriteToBigQuery(
                table='project:dataset.error_logs',
                schema='error:STRING,raw_data:STRING,processed_at:TIMESTAMP',
                write_disposition=WriteToBigQuery.WriteDisposition.WRITE_APPEND
            )
        )

if __name__ == '__main__':
    import os
    run_streaming_pipeline()

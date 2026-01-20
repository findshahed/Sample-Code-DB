# data_processing/dataflow_pipeline.py
# This python code creates dataflow pipeline
#
import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions
from validation_logic import TradeValidator
import json
import datetime

class ProcessTrades(beam.DoFn):
    def __init__(self, existing_trades_table):
        self.existing_trades_table = existing_trades_table
    
    def process(self, element):
        from google.cloud import bigquery
        import json
        
        trade = json.loads(element.decode('utf-8'))
        validator = TradeValidator()
        
        # Check existing trades in BigQuery
        client = bigquery.Client()
        query = f"""
            SELECT version FROM `{self.existing_trades_table}`
            WHERE trade_id = '{trade['trade_id']}'
            ORDER BY version DESC LIMIT 1
        """
        
        try:
            query_job = client.query(query)
            existing_version = None
            for row in query_job:
                existing_version = row.version
            
            # Apply business rules
            is_valid, reason = validator.validate_trade(trade, existing_version)
            
            if is_valid:
                trade['processed_at'] = datetime.datetime.utcnow().isoformat()
                trade['status'] = 'VALID'
                yield beam.pvalue.TaggedOutput('valid_trades', trade)
            elif reason == 'EXPIRED':
                trade['processed_at'] = datetime.datetime.utcnow().isoformat()
                trade['status'] = 'EXPIRED'
                yield beam.pvalue.TaggedOutput('expired_trades', trade)
            else:
                trade['processed_at'] = datetime.datetime.utcnow().isoformat()
                trade['rejection_reason'] = reason
                trade['status'] = 'REJECTED'
                yield beam.pvalue.TaggedOutput('rejected_trades', trade)
                
        except Exception as e:
            trade['error'] = str(e)
            trade['status'] = 'ERROR'
            yield beam.pvalue.TaggedOutput('error_trades', trade)

def run_pipeline(project, input_topic, valid_table, rejected_table, expired_table):
    options = PipelineOptions(
        project=project,
        runner='DataflowRunner',
        region='us-central1',
        temp_location=f'gs://{project}-temp/temp',
        streaming=True
    )
    
    with beam.Pipeline(options=options) as pipeline:
        # Read from Pub/Sub
        messages = (
            pipeline
            | 'Read from Pub/Sub' >> beam.io.ReadFromPubSub(topic=input_topic)
        )
        
        # Process and validate trades
        processed = (
            messages
            | 'Process Trades' >> beam.ParDo(
                ProcessTrades(valid_table)
            ).with_outputs('valid_trades', 'rejected_trades', 'expired_trades', 'error_trades')
        )
        
        # Write valid trades to BigQuery
        _ = (
            processed.valid_trades
            | 'Write Valid Trades' >> beam.io.WriteToBigQuery(
                valid_table,
                schema='trade_id:STRING,version:INTEGER,counterparty_id:STRING,'
                      'instrument_id:STRING,quantity:INTEGER,price:FLOAT,'
                      'trade_type:STRING,currency:STRING,trade_date:TIMESTAMP,'
                      'maturity_date:TIMESTAMP,status:STRING,processed_at:TIMESTAMP',
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED
            )
        )
        
        # Write rejected trades to BigQuery
        _ = (
            processed.rejected_trades
            | 'Write Rejected Trades' >> beam.io.WriteToBigQuery(
                rejected_table,
                schema='trade_id:STRING,version:INTEGER,rejection_reason:STRING,'
                      'trade_data:STRING,processed_at:TIMESTAMP',
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED
            )
        )
        
        # Write expired trades to BigQuery
        _ = (
            processed.expired_trades
            | 'Write Expired Trades' >> beam.io.WriteToBigQuery(
                expired_table,
                schema='trade_id:STRING,version:INTEGER,counterparty_id:STRING,'
                      'instrument_id:STRING,quantity:INTEGER,price:FLOAT,'
                      'trade_type:STRING,currency:STRING,trade_date:TIMESTAMP,'
                      'maturity_date:TIMESTAMP,status:STRING,processed_at:TIMESTAMP',
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED
            )
        )

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', required=True)
    parser.add_argument('--input_topic', required=True)
    parser.add_argument('--valid_table', required=True)
    parser.add_argument('--rejected_table', required=True)
    parser.add_argument('--expired_table', required=True)
    
    args = parser.parse_args()
    run_pipeline(
        args.project,
        args.input_topic,
        args.valid_table,
        args.rejected_table,
        args.expired_table
    )

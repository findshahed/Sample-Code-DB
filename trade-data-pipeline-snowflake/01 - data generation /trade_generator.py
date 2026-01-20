# data_generation/trade_generator.py
# This code generates random trades and publishes it into GCP Pub/SUB topic
#
import json
import random
import datetime
from google.cloud import pubsub_v1
import time

class TradeGenerator:
    def __init__(self, project_id, topic_id):
        self.publisher = pubsub_v1.PublisherClient()
        self.topic_path = self.publisher.topic_path(project_id, topic_id)
    
    def generate_trade(self):
        """Generate mock trade data"""
        trade_types = ['BUY', 'SELL']
        currencies = ['USD', 'EUR', 'GBP', 'JPY']
        
        trade = {
            'trade_id': f"TRD{random.randint(10000, 99999)}",
            'version': random.randint(1, 5),
            'counterparty_id': f"CP{random.randint(100, 999)}",
            'instrument_id': f"INST{random.randint(1000, 9999)}",
            'quantity': random.randint(100, 10000),
            'price': round(random.uniform(10.0, 1000.0), 2),
            'trade_type': random.choice(trade_types),
            'currency': random.choice(currencies),
            'trade_date': datetime.datetime.utcnow().isoformat(),
            'maturity_date': (
                datetime.datetime.utcnow() + 
                datetime.timedelta(days=random.randint(-10, 30))
            ).isoformat(),
            'status': 'NEW',
            'created_at': datetime.datetime.utcnow().isoformat()
        }
        return trade
    
    def publish_trades(self, num_trades=1000, delay=0.1):
        """Publish trades to Pub/Sub"""
        for _ in range(num_trades):
            trade = self.generate_trade()
            data = json.dumps(trade).encode('utf-8')
            future = self.publisher.publish(self.topic_path, data)
            print(f"Published trade: {trade['trade_id']}")
            time.sleep(delay)

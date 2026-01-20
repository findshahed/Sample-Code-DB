# data_processing/validation_logic.py
# This python script validates trades recieved from pub/sub topic
#
import datetime

class TradeValidator:
    def validate_trade(self, trade, existing_version=None):
        """
        Validate trade against business rules:
        1. Reject trades with lower version than existing
        2. Replace trades with same version
        3. Reject trades with maturity date earlier than today
        4. Mark trades as expired if maturity date has passed
        """
        current_version = trade.get('version', 0)
        
        # Rule 1: Check version
        if existing_version and current_version < existing_version:
            return False, 'LOWER_VERSION'
        
        # Parse maturity date
        try:
            if isinstance(trade['maturity_date'], str):
                maturity_date = datetime.datetime.fromisoformat(
                    trade['maturity_date'].replace('Z', '+00:00')
                )
            else:
                maturity_date = trade['maturity_date']
            
            today = datetime.datetime.utcnow().date()
            maturity_date_date = maturity_date.date()
            
            # Rule 3: Reject trades with maturity date earlier than today
            if maturity_date_date < today:
                return False, 'MATURITY_DATE_PASSED'
            
            # Rule 4: Mark as expired if maturity date has passed (for same day)
            if maturity_date_date == today and maturity_date < datetime.datetime.utcnow():
                return True, 'EXPIRED'
                
        except (KeyError, ValueError) as e:
            return False, f'INVALID_DATE_FORMAT: {str(e)}'
        
        # All rules passed
        return True, 'VALID'

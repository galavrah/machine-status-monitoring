#!/usr/bin/env python3

import os
import json
import logging
from typing import Dict, Any

import paho.mqtt.client as mqtt
import sqlalchemy as sa
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-subscriber.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# SQLAlchemy Base and Session setup
Base = declarative_base()

class MachineStatus(Base):
    """
    Database model to store machine status information
    """
    __tablename__ = 'machine_statuses'

    id = sa.Column(sa.Integer, primary_key=True)
    machine_id = sa.Column(sa.String(255), nullable=False, index=True)
    hostname = sa.Column(sa.String(255), nullable=False)
    ip_address = sa.Column(sa.String(100))
    cpu_model = sa.Column(sa.String(255))
    cpu_cores = sa.Column(sa.Integer)
    cpu_usage = sa.Column(sa.Float)
    memory_total = sa.Column(sa.String(50))
    memory_available = sa.Column(sa.String(50))
    memory_usage = sa.Column(sa.Float)
    storage_total = sa.Column(sa.String(50))
    storage_free = sa.Column(sa.String(50))
    storage_usage = sa.Column(sa.Float)
    timestamp = sa.Column(sa.DateTime, server_default=sa.func.now())

class MachineStatusSubscriber:
    def __init__(
        self, 
        broker_address: str = 'localhost', 
        broker_port: int = 1883, 
        username: str = 'machine_status', 
        password: str = None,
        database_url: str = None
    ):
        """
        Initialize MQTT Machine Status Subscriber
        
        :param broker_address: MQTT Broker address
        :param broker_port: MQTT Broker port
        :param username: MQTT Broker username
        :param password: MQTT Broker password
        :param database_url: SQLAlchemy database connection string
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = broker_address
        self.broker_port = broker_port
        
        # Database setup
        if not database_url:
            database_url = os.getenv(
                'DATABASE_URL', 
                'postgresql://username:password@localhost/machine_status_db'
            )
        self.engine = sa.create_engine(database_url)
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine)

        # Set up MQTT authentication
        if username and password:
            self.client.username_pw_set(username, password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        
        :param client: MQTT client instance
        :param userdata: Private user data
        :param flags: Response flags
        :param rc: Return code
        """
        if rc == 0:
            logging.info("Connected to MQTT Broker successfully")
            # Subscribe to machine status topic
            client.subscribe("machine_status/#")
        else:
            logging.error(f"Failed to connect to MQTT Broker. Return code: {rc}")

    def _on_message(self, client, userdata, msg):
        """
        Callback for when a message is received from the server.
        
        :param client: MQTT client instance
        :param userdata: Private user data
        :param msg: MQTT message
        """
        try:
            # Decode payload
            payload = msg.payload.decode('utf-8')
            machine_info = json.loads(payload)
            
            # Store in database
            self._store_machine_status(machine_info)
            
            logging.info(f"Received status for machine {machine_info.get('machine_id')}")
        
        except json.JSONDecodeError:
            logging.error(f"Failed to decode JSON from topic {msg.topic}")
        except Exception as e:
            logging.error(f"Error processing message: {e}")

    def _store_machine_status(self, machine_info: Dict[str, Any]):
        """
        Store machine status in database
        
        :param machine_info: Dictionary of machine status information
        """
        try:
            # Create database session
            session = self.Session()
            
            # Create MachineStatus record
            status_record = MachineStatus(
                machine_id=machine_info.get('machine_id', 'Unknown'),
                hostname=machine_info.get('hostname', 'Unknown'),
                ip_address=machine_info.get('ip_address', ''),
                cpu_model=machine_info.get('cpu', {}).get('model', 'Unknown'),
                cpu_cores=machine_info.get('cpu', {}).get('cores', 0),
                cpu_usage=machine_info.get('cpu', {}).get('usage_percent', 0),
                memory_total=machine_info.get('memory', {}).get('total', 'Unknown'),
                memory_available=machine_info.get('memory', {}).get('available', 'Unknown'),
                memory_usage=machine_info.get('memory', {}).get('usage_percent', 0),
                storage_total=machine_info.get('storage', {}).get('total', 'Unknown'),
                storage_free=machine_info.get('storage', {}).get('free', 'Unknown'),
                storage_usage=machine_info.get('storage', {}).get('usage_percent', 0)
            )
            
            # Add and commit record
            session.add(status_record)
            session.commit()
        
        except Exception as e:
            session.rollback()
            logging.error(f"Error storing machine status: {e}")
        finally:
            session.close()

    def _on_disconnect(self, client, userdata, rc):
        """
        MQTT disconnection callback
        
        :param client: MQTT client instance
        :param userdata: Private user data
        :param rc: Return code
        """
        logging.warning(f"Disconnected from MQTT Broker. Return code: {rc}")
        # Attempt to reconnect
        try:
            client.reconnect()
        except Exception as e:
            logging.error(f"Reconnection failed: {e}")

    def run(self):
        """
        Run the MQTT Machine Status Subscriber
        """
        try:
            # Connect to MQTT Broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start MQTT loop
            logging.info("Starting MQTT Machine Status Subscriber")
            self.client.loop_forever()
        
        except Exception as e:
            logging.error(f"Fatal error in subscriber: {e}")
        finally:
            # Ensure clean disconnection
            self.client.disconnect()

def main():
    # Configuration defaults 
    database_url = None
    
    # Try to load database configuration from environment file
    db_env_file = '/etc/machine-status/db.env'
    if os.path.exists(db_env_file):
        try:
            with open(db_env_file, 'r') as f:
                for line in f:
                    if '=' in line and line.startswith('DATABASE_URL'):
                        _, database_url = line.strip().split('=', 1)
                        break
        except Exception as e:
            logging.error(f"Error reading database config: {e}")
    
    # If no database configuration was found, check for environment variables
    if not database_url:
        database_url = os.getenv('DATABASE_URL')
    
    # If still no database configuration, prompt for credentials
    if not database_url:
        print("No database configuration found. Please enter database credentials:")
        db_user = input("Database username: ")
        db_pass = input("Database password: ")
        db_name = input("Database name [machine_status_db]: ") or "machine_status_db"
        db_host = input("Database host [localhost]: ") or "localhost"
        database_url = f"postgresql://{db_user}:{db_pass}@{db_host}/{db_name}"
    
    # Get MQTT configuration
    broker_address = os.getenv('MQTT_BROKER_ADDRESS', 'localhost')
    broker_port = int(os.getenv('MQTT_BROKER_PORT', 1883))
    username = os.getenv('MQTT_USERNAME', 'machine_status_user')
    password = os.getenv('MQTT_PASSWORD', '123456')
    
    # Print configuration (without password)
    print(f"Using database: {database_url.split(':')[0]}://{database_url.split(':')[1].split('@')[0]}:***@{database_url.split('@')[1]}")
    print(f"Using MQTT broker: {broker_address}:{broker_port}")
    
    # Create and run subscriber
    subscriber = MachineStatusSubscriber(
        broker_address=broker_address,
        broker_port=broker_port,
        username=username,
        password=password,
        database_url=database_url
    )
    
    # Run the subscriber
    subscriber.run()

if __name__ == "__main__":
    main()
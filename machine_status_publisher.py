#!/usr/bin/env python3

import os
import time
import json
import socket
import psutil
import netifaces
import paho.mqtt.client as mqtt
import logging
from typing import Dict, Any

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-publisher.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class MachineStatusPublisher:
    def __init__(
        self, 
        broker_address: str = 'localhost', 
        broker_port: int = 1883, 
        username: str = 'machine_status', 
        password: str = None, 
        publish_interval: int = 60
    ):
        """
        Initialize MQTT Machine Status Publisher
        
        :param broker_address: MQTT Broker address
        :param broker_port: MQTT Broker port
        :param username: MQTT Broker username
        :param password: MQTT Broker password
        :param publish_interval: Interval between status updates in seconds
        """
        self.broker_address = broker_address
        self.broker_port = broker_port
        self.username = username
        self.password = password or self._load_password()
        self.publish_interval = publish_interval
        
        # Generate unique machine ID
        self.machine_id = self._get_machine_id()
        
        # MQTT Client setup
        self.client = mqtt.Client(client_id=self.machine_id)
        self.client.username_pw_set(username, password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_publish = self._on_publish
        self.client.on_disconnect = self._on_disconnect

    def _load_password(self) -> str:
        """
        Load MQTT broker password from a secure file
        
        :return: MQTT broker password
        """
        try:
            with open('/etc/machine-status/mqtt_password', 'r') as f:
                return f.read().strip()
        except Exception as e:
            logging.error(f"Failed to load MQTT password: {e}")
            raise

    def _get_machine_id(self) -> str:
        """
        Generate a unique machine identifier
        
        :return: Unique machine identifier (MAC address)
        """
        try:
            # Get MAC address of primary network interface
            interfaces = netifaces.interfaces()
            for iface in interfaces:
                if iface.startswith(('eth', 'wlan', 'en', 'wlp')):
                    addrs = netifaces.ifaddresses(iface)
                    if netifaces.AF_LINK in addrs:
                        return addrs[netifaces.AF_LINK][0]['addr']
        except Exception as e:
            logging.error(f"Failed to get MAC address: {e}")
        
        # Fallback to hostname if MAC address retrieval fails
        return socket.gethostname()

    def _get_machine_info(self) -> Dict[str, Any]:
        """
        Collect comprehensive machine information
        
        :return: Dictionary of machine information
        """
        def format_storage_capacity(value_bytes: int) -> str:
            """Format storage capacity to human-readable format"""
            if value_bytes >= 1024 ** 4:  # 1 TB
                return f"{value_bytes / (1024 ** 4):.2f} T"
            elif value_bytes >= 1024 ** 3:  # 1 GB
                return f"{value_bytes / (1024 ** 3):.2f} G"
            else:
                return f"{value_bytes} B"

        def get_network_info() -> str:
            """Get primary network interface IP"""
            interfaces = netifaces.interfaces()
            for iface in interfaces:
                if iface.startswith(('wlp', 'wls', 'eth', 'en')):
                    addrs = netifaces.ifaddresses(iface)
                    if netifaces.AF_INET in addrs:
                        return addrs[netifaces.AF_INET][0]['addr']
            return ""

        # Collect comprehensive system information
        return {
            "machine_id": self.machine_id,
            "hostname": socket.gethostname(),
            "ip_address": get_network_info(),
            "cpu": {
                "model": self._get_cpu_model(),
                "cores": psutil.cpu_count(),
                "usage_percent": psutil.cpu_percent()
            },
            "memory": {
                "total": f"{psutil.virtual_memory().total / (1024 ** 3):.2f} GB",
                "available": f"{psutil.virtual_memory().available / (1024 ** 3):.2f} GB",
                "usage_percent": psutil.virtual_memory().percent
            },
            "storage": {
                "total": format_storage_capacity(psutil.disk_usage('/').total),
                "free": format_storage_capacity(psutil.disk_usage('/').free),
                "usage_percent": psutil.disk_usage('/').percent
            },
            "timestamp": time.time()
        }

    def _get_cpu_model(self) -> str:
        """
        Get CPU model information
        
        :return: CPU model as string
        """
        try:
            with open('/proc/cpuinfo', 'r') as f:
                for line in f:
                    if "model name" in line:
                        return line.split(':')[1].strip()
        except Exception as e:
            logging.error(f"Failed to read CPU model: {e}")
        return "Unknown CPU"

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
        else:
            logging.error(f"Failed to connect to MQTT Broker. Return code: {rc}")

    def _on_publish(self, client, userdata, mid):
        """
        MQTT message publish callback
        
        :param client: MQTT client instance
        :param userdata: Private user data
        :param mid: Message ID
        """
        logging.info(f"Message {mid} published successfully")

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
            self.client.reconnect()
        except Exception as e:
            logging.error(f"Reconnection failed: {e}")

    def publish_status(self):
        """
        Publish machine status to MQTT topic
        """
        try:
            # Get current machine information
            machine_info = self._get_machine_info()
            
            # Convert to JSON
            payload = json.dumps(machine_info)
            
            # Publish to MQTT topic
            topic = f"machine_status/{self.machine_id}"
            result = self.client.publish(topic, payload)
            
            # Check if publish was successful
            if result.rc != mqtt.MQTT_ERR_SUCCESS:
                logging.error(f"Failed to publish message. Error code: {result.rc}")
        
        except Exception as e:
            logging.error(f"Error publishing machine status: {e}")

    def run(self):
        """
        Run the MQTT machine status publisher
        """
        try:
            # Connect to MQTT Broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start MQTT loop in background
            self.client.loop_start()
            
            # Publish status periodically
            while True:
                self.publish_status()
                time.sleep(self.publish_interval)
        
        except Exception as e:
            logging.error(f"Fatal error in publisher: {e}")
        finally:
            # Ensure clean disconnection
            self.client.loop_stop()
            self.client.disconnect()

def main():
    # Configuration can be loaded from environment or config file
    BROKER_ADDRESS = os.getenv('MQTT_BROKER_ADDRESS', 'localhost')
    BROKER_PORT = int(os.getenv('MQTT_BROKER_PORT', 1883))
    USERNAME = os.getenv('MQTT_USERNAME', 'machine_status')
    PASSWORD_FILE = os.getenv('MQTT_PASSWORD_FILE', '/etc/machine-status/mqtt_password')
    PUBLISH_INTERVAL = int(os.getenv('PUBLISH_INTERVAL', 60))

    # Read password from file
    with open(PASSWORD_FILE, 'r') as f:
        PASSWORD = f.read().strip()

    # Create and run publisher
    publisher = MachineStatusPublisher(
        broker_address=BROKER_ADDRESS,
        broker_port=BROKER_PORT,
        username=USERNAME,
        password=PASSWORD,
        publish_interval=PUBLISH_INTERVAL
    )
    
    # Run the publisher
    publisher.run()

if __name__ == "__main__":
    main()
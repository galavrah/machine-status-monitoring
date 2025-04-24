#!/usr/bin/env python3

import os
import time
import json
import socket
import psutil
import netifaces
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
        database_url: str = None,
        publish_interval: int = 60
    ):
        """
        Initialize Machine Status Publisher
        
        :param database_url: Database connection URL
        :param publish_interval: Interval between status updates in seconds
        """
        self.publish_interval = publish_interval
        
        # Load database connection details
        self.database_url = database_url or self._load_database_url()
        
        # Generate unique machine ID
        self.machine_id = self._get_machine_id()

    def _load_database_url(self) -> str:
        """
        Load database connection URL from environment file
        
        :return: Database connection URL
        """
        try:
            with open('/etc/machine-status/db.env', 'r') as f:
                for line in f:
                    if line.startswith('DATABASE_URL='):
                        return line.split('=', 1)[1].strip()
        except Exception as e:
            logging.error(f"Failed to load database URL: {e}")
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

        def get_cpu_model() -> str:
            """Get CPU model information"""
            try:
                with open('/proc/cpuinfo', 'r') as f:
                    for line in f:
                        if "model name" in line:
                            return line.split(':')[1].strip()
            except Exception as e:
                logging.error(f"Failed to read CPU model: {e}")
            return "Unknown CPU"

        # Collect comprehensive system information
        return {
            "machine_id": self.machine_id,
            "hostname": socket.gethostname(),
            "ip_address": get_network_info(),
            "cpu": {
                "model": get_cpu_model(),
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

    def publish_status(self):
        """
        Publish machine status to database or logging
        """
        try:
            # Get current machine information
            machine_info = self._get_machine_info()
            
            # Log the information
            logging.info(f"Machine Status: {json.dumps(machine_info, indent=2)}")
            
            # TODO: Add database insertion logic here if needed
        
        except Exception as e:
            logging.error(f"Error publishing machine status: {e}")

    def run(self):
        """
        Run the machine status publisher
        """
        try:
            logging.info("Starting Machine Status Publisher")
            
            # Publish status periodically
            while True:
                self.publish_status()
                time.sleep(self.publish_interval)
        
        except Exception as e:
            logging.error(f"Fatal error in publisher: {e}")

def main():
    # Configuration from environment or defaults
    PUBLISH_INTERVAL = int(os.getenv('PUBLISH_INTERVAL', 60))
    DATABASE_URL = os.getenv('DATABASE_URL')

    # Create and run publisher
    publisher = MachineStatusPublisher(
        database_url=DATABASE_URL,
        publish_interval=PUBLISH_INTERVAL
    )
    
    # Run the publisher
    publisher.run()

if __name__ == "__main__":
    main()
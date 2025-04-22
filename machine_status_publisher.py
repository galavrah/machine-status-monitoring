#!/usr/bin/env python3
import os
import time
import json
import socket
import requests
import psutil
import netifaces
import glob
import logging
from typing import Dict, Any

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-publisher.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class MachineStatusPublisher:
    def __init__(self, server_url: str, publish_interval: int = 60):
        """
        Initialize the Machine Status Publisher
        
        :param server_url: URL of the server endpoint to send machine status
        :param publish_interval: Interval between status updates in seconds
        """
        self.server_url = server_url
        self.publish_interval = publish_interval
        self.machine_id = self._get_machine_id()

    def _get_machine_id(self) -> str:
        """
        Generate a unique machine identifier
        
        :return: Unique machine identifier (MAC address)
        """
        try:
            return self._get_mac_address()
        except Exception as e:
            logging.error(f"Failed to get machine ID: {e}")
            return socket.gethostname()

    def _get_mac_address(self) -> str:
        """
        Get the MAC address of the primary network interface
        
        :return: MAC address as a string
        """
        SCN = "/sys/class/net"
        min_idx = 65535
        arphrd_ether = 1
        ifdev = None

        for dev in glob.glob(os.path.join(SCN, "*")):
            if not os.path.exists(os.path.join(dev, "type")):
                continue

            path = os.path.join(dev, "type")
            with open(path, "r") as type_file:
                iftype = type_file.read().strip()

            if int(iftype) != arphrd_ether:
                continue

            # Skip dummy interfaces
            if "dummy" in dev:
                continue

            path = os.path.join(dev, "ifindex")
            with open(path, "r") as ifindex_file:
                idx = int(ifindex_file.read().strip())

            if idx < min_idx:
                min_idx = idx
                ifdev = dev

        if not ifdev:
            raise Exception("No suitable interfaces found")

        # Grab MAC address
        path = os.path.join(ifdev, "address")
        with open(path, "r") as mac_file:
            return mac_file.read().strip()

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

        def get_cpu_info() -> str:
            """Get CPU model information"""
            try:
                with open('/proc/cpuinfo', 'r') as f:
                    for line in f:
                        if "model name" in line:
                            return line.split(':')[1].strip()
            except Exception:
                return "Unknown"
            return "Unknown"

        def get_memory_info() -> str:
            """Get total memory"""
            try:
                total_memory_kb = psutil.virtual_memory().total
                return f"{total_memory_kb / (1024 ** 3):.2f} GB"
            except Exception:
                return "Unknown"

        def get_storage_info() -> Dict[str, Any]:
            """Get storage information"""
            try:
                disk_partitions = psutil.disk_partitions()
                for partition in disk_partitions:
                    # You can customize this to check for specific mount points
                    if partition.mountpoint == '/':
                        usage = psutil.disk_usage(partition.mountpoint)
                        return {
                            "total": {"int": usage.total, "str": format_storage_capacity(usage.total)},
                            "used": {"int": usage.used, "str": format_storage_capacity(usage.used)},
                            "free": {"int": usage.free, "str": format_storage_capacity(usage.free)},
                            "percentage": {"str": f"{usage.percent:.2f}%"}
                        }
            except Exception:
                pass
            
            return {
                "total": {"int": 0, "str": ""},
                "used": {"int": 0, "str": ""},
                "free": {"int": 0, "str": ""},
                "percentage": {"str": ""}
            }

        return {
            "machine_id": self.machine_id,
            "hostname": socket.gethostname(),
            "ip": get_network_info(),
            "cpu_model": get_cpu_info(),
            "memory": get_memory_info(),
            "storage": get_storage_info(),
            "cpu_usage": f"{psutil.cpu_percent()}%",
            "memory_usage": f"{psutil.virtual_memory().percent}%",
            "timestamp": time.time()
        }

    def publish_status(self) -> bool:
        """
        Publish machine status to the server
        
        :return: True if successful, False otherwise
        """
        try:
            machine_info = self._get_machine_info()
            response = requests.post(
                self.server_url, 
                json=machine_info, 
                timeout=10
            )
            
            if response.status_code == 200:
                logging.info("Machine status published successfully")
                return True
            else:
                logging.error(f"Failed to publish status. Status code: {response.status_code}")
                return False
        except requests.RequestException as e:
            logging.error(f"Error publishing machine status: {e}")
            return False

    def run(self):
        """
        Continuously publish machine status at specified intervals
        """
        logging.info("Machine Status Publisher started")
        while True:
            try:
                self.publish_status()
                time.sleep(self.publish_interval)
            except Exception as e:
                logging.error(f"Unexpected error in publisher: {e}")
                time.sleep(self.publish_interval)

def main():
    # Server URL where machine status will be sent
    SERVER_URL = 'http://your-server-address.com/machine-status'
    
    # Interval between status updates (in seconds)
    PUBLISH_INTERVAL = 60  # 1 minute
    
    publisher = MachineStatusPublisher(SERVER_URL, PUBLISH_INTERVAL)
    publisher.run()

if __name__ == "__main__":
    main()
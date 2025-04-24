#!/usr/bin/env python3

import os
import json
import time
import argparse
import threading
from datetime import datetime
from typing import Dict, Any, List, Optional
import paho.mqtt.client as mqtt

# Global dictionary to store machine statuses
machines = {}
# Lock for thread-safe access to the machines dictionary
machines_lock = threading.Lock()

class MachineStatusSubscriber:
    def __init__(
        self, 
        broker_address: str = 'localhost', 
        broker_port: int = 1883, 
        username: str = None, 
        password: str = None,
        offline_threshold: int = 60  # Seconds before marking a machine as offline
    ):
        """
        Initialize MQTT Machine Status Subscriber
        
        :param broker_address: MQTT Broker address
        :param broker_port: MQTT Broker port
        :param username: MQTT Broker username (optional)
        :param password: MQTT Broker password (optional)
        :param offline_threshold: Time in seconds before a machine is considered offline
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = broker_address
        self.broker_port = broker_port
        self.offline_threshold = offline_threshold
        
        # Set up MQTT authentication if provided
        if username and password:
            self.client.username_pw_set(username, password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        
        # Status flags
        self.connected = False
        self.running = False
        
        # Start offline detector thread
        self.offline_detector_thread = None

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        """
        if rc == 0:
            print(f"Connected to MQTT Broker at {self.broker_address}:{self.broker_port}")
            # Subscribe to all machine status topics
            client.subscribe("machine_status/#")
            self.connected = True
        else:
            print(f"Failed to connect to MQTT Broker. Return code: {rc}")

    def _on_message(self, client, userdata, msg):
        """
        Callback for when a message is received from the server
        """
        try:
            # Decode payload
            payload = msg.payload.decode('utf-8')
            data = json.loads(payload)
            
            # Extract topic parts
            topic_parts = msg.topic.split('/')
            
            # Handle status-specific messages (machine_status/<machine_id>/status)
            if len(topic_parts) >= 3 and topic_parts[2] == "status":
                machine_id = topic_parts[1]
                status = data.get('status', 'unknown')
                
                # Update machine status if it exists
                with machines_lock:
                    if machine_id in machines:
                        machines[machine_id]['online_status'] = status
                        print(f"Machine {machine_id} status updated to: {status}")
                return
            
            # Handle regular machine status updates (machine_status/<machine_id>)
            if 'machine_id' in data:
                machine_id = data.get('machine_id')
                
                # Create or update machine in the dictionary
                with machines_lock:
                    machines[machine_id] = {
                        'hostname': data.get('hostname', 'Unknown'),
                        'ip_address': data.get('ip_address', ''),
                        'cpu': {
                            'model': data.get('cpu', {}).get('model', 'Unknown'),
                            'cores': data.get('cpu', {}).get('cores', 0),
                            'usage_percent': data.get('cpu', {}).get('usage_percent', 0)
                        },
                        'memory': {
                            'total': data.get('memory', {}).get('total', 'Unknown'),
                            'available': data.get('memory', {}).get('available', 'Unknown'),
                            'usage_percent': data.get('memory', {}).get('usage_percent', 0)
                        },
                        'storage': {
                            'total': data.get('storage', {}).get('total', 'Unknown'),
                            'free': data.get('storage', {}).get('free', 'Unknown'),
                            'usage_percent': data.get('storage', {}).get('usage_percent', 0)
                        },
                        'online_status': data.get('online_status', 'online'),
                        'last_seen': datetime.now()
                    }
                
                # Print machine information if requested
                self._print_machine_update(machine_id, machines[machine_id])
        
        except json.JSONDecodeError:
            print(f"Failed to decode JSON from topic {msg.topic}")
        except Exception as e:
            print(f"Error processing message: {e}")

    def _on_disconnect(self, client, userdata, rc):
        """
        MQTT disconnection callback
        """
        print(f"Disconnected from MQTT Broker. Return code: {rc}")
        self.connected = False
        # Attempt to reconnect if needed
        if self.running:
            try:
                client.reconnect()
            except Exception as e:
                print(f"Reconnection failed: {e}")

    def _print_machine_update(self, machine_id, machine):
        """
        Print information about a specific machine update (if printing is enabled)
        """
        print(f"\n===== Machine Status Update: {machine_id} =====")
        print(f"Hostname: {machine['hostname']}")
        print(f"IP Address: {machine['ip_address']}")
        print(f"CPU: {machine['cpu']['usage_percent']:.1f}% ({machine['cpu']['cores']} cores)")
        print(f"Memory: {machine['memory']['usage_percent']:.1f}% (Total: {machine['memory']['total']})")
        print(f"Storage: {machine['storage']['usage_percent']:.1f}% (Free: {machine['storage']['free']})")
        print(f"Status: {machine['online_status']}")
        print("=" * 50)

    def _offline_detector(self):
        """
        Background thread to detect offline machines
        """
        while self.running:
            now = datetime.now()
            with machines_lock:
                for machine_id, machine in list(machines.items()):
                    if 'last_seen' in machine and machine['online_status'] != 'offline':
                        time_diff = now - machine['last_seen']
                        if time_diff.total_seconds() > self.offline_threshold:
                            print(f"Machine {machine_id} ({machine['hostname']}) marked as offline - no data for {self.offline_threshold}s")
                            machines[machine_id]['online_status'] = 'offline'
            
            # Check every 5 seconds
            time.sleep(5)

    def start(self):
        """
        Connect to broker and start listening
        """
        if self.running:
            return
            
        self.running = True
        try:
            # Connect to the broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start the loop in a non-blocking way
            self.client.loop_start()
            
            # Start offline detector thread
            self.offline_detector_thread = threading.Thread(
                target=self._offline_detector, 
                daemon=True
            )
            self.offline_detector_thread.start()
            
            print(f"Monitoring machine status with {self.offline_threshold}s offline threshold")
        except Exception as e:
            print(f"Error connecting to broker {self.broker_address}: {e}")
            self.running = False
    
    def stop(self):
        """
        Stop listening and disconnect
        """
        if not self.running:
            return
            
        self.running = False
        self.client.loop_stop()
        if self.connected:
            self.client.disconnect()


def print_all_machines():
    """
    Print a summary of all machines
    """
    with machines_lock:
        if not machines:
            print("No machines connected yet")
            return
            
        print("\n===== MACHINE STATUS SUMMARY =====")
        print(f"Total machines: {len(machines)}")
        print("=" * 60)
        
        # Sort machines by hostname
        sorted_machines = sorted(machines.items(), key=lambda x: x[1]['hostname'])
        
        for machine_id, machine in sorted_machines:
            # Calculate time since last seen
            if 'last_seen' in machine:
                time_diff = datetime.now() - machine['last_seen']
                if time_diff.total_seconds() < 60:
                    last_seen = f"{int(time_diff.total_seconds())} seconds ago"
                else:
                    last_seen = f"{int(time_diff.total_seconds() / 60)} minutes ago"
            else:
                last_seen = "Unknown"
            
            # Format status
            if machine['online_status'] == 'online':
                status = "ONLINE"
            elif machine['online_status'] == 'offline':
                status = "OFFLINE"
            else:
                status = "UNKNOWN"
            
            print(f"{machine['hostname']} ({machine['ip_address']})")
            print(f"  Status: {status}, Last seen: {last_seen}")
            print(f"  CPU: {machine['cpu']['usage_percent']:.1f}%, Memory: {machine['memory']['usage_percent']:.1f}%, Storage: {machine['storage']['usage_percent']:.1f}%")
            print("-" * 60)
        
        print("")

def get_machine_status(machine_id: str = None) -> Dict:
    """
    Get the current status of machines
    
    :param machine_id: Specific machine ID to query, or None for all machines
    :return: Dict containing machine status information
    """
    with machines_lock:
        if machine_id is not None:
            return machines.get(machine_id, {}).copy()
        else:
            # Return a copy to avoid thread safety issues
            return machines.copy()

def start_monitoring(
    broker_address: str = 'localhost',
    broker_port: int = 1883,
    username: str = None,
    password: str = None,
    offline_threshold: int = 60,
    update_interval: int = 10
) -> MachineStatusSubscriber:
    """
    Start monitoring multiple machines from a single MQTT broker
    
    :param broker_address: MQTT broker address
    :param broker_port: MQTT broker port
    :param username: Optional username for broker authentication
    :param password: Optional password for broker authentication
    :param offline_threshold: Time in seconds before a machine is considered offline
    :param update_interval: Time in seconds between summary updates (0 to disable)
    :return: MachineStatusSubscriber instance
    """
    # Create and start the subscriber
    subscriber = MachineStatusSubscriber(
        broker_address=broker_address,
        broker_port=broker_port,
        username=username,
        password=password,
        offline_threshold=offline_threshold
    )
    
    # Start the subscriber
    subscriber.start()
    
    # Start update loop in a separate thread if needed
    if update_interval > 0:
        def update_loop():
            try:
                while True:
                    time.sleep(update_interval)
                    print_all_machines()
            except Exception as e:
                print(f"Error in update loop: {e}")
        
        update_thread = threading.Thread(target=update_loop, daemon=True)
        update_thread.start()
    
    return subscriber

def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='MQTT Machine Status Subscriber')
    parser.add_argument('--broker', '-b', default='localhost',
                        help='MQTT broker address (default: localhost)')
    parser.add_argument('--port', '-p', type=int, default=1883,
                        help='MQTT broker port (default: 1883)')
    parser.add_argument('--username', '-u', help='MQTT username')
    parser.add_argument('--password', '-P', help='MQTT password')
    parser.add_argument('--offline-threshold', '-t', type=int, default=60, 
                        help='Time in seconds before a machine is considered offline (default: 60)')
    parser.add_argument('--update-interval', '-i', type=int, default=10,
                        help='Time in seconds between summary updates (default: 10)')
    return parser.parse_args()

def run_from_command_line():
    """Run the script from command line with arguments"""
    args = parse_arguments()
    
    # Start monitoring
    subscriber = start_monitoring(
        broker_address=args.broker,
        broker_port=args.port,
        username=args.username,
        password=args.password,
        offline_threshold=args.offline_threshold,
        update_interval=args.update_interval
    )
    
    try:
        # Keep the main thread running
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        # Clean up
        subscriber.stop()

# if __name__ == "__main__":
#     run_from_command_line()
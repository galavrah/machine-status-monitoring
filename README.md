# Machine Status Monitoring System

A comprehensive system for monitoring machine status across your network using MQTT. This system provides real-time tracking of CPU, memory, and storage usage, as well as online/offline status detection.

## Components

- **Publisher**: Collects and publishes system information from client machines
- **Subscriber**: Receives and processes status updates from multiple machines
- **Unified Installer**: Single script to set up either server or client components

## Features

- Real-time machine status monitoring (CPU, memory, disk usage)
- Automatic online/offline status detection
- 5-second status update interval
- PostgreSQL database storage for historical data
- Web dashboard for visualizing machine status
- Command-line monitoring tools

## Installation

### Prerequisites

- Linux-based operating system (Ubuntu, Debian, Fedora, CentOS, or RHEL)
- Python 3.6 or higher
- Root/sudo privileges

### Quick Installation

#### Server Setup (Broker + Subscriber + Database)

```bash
# Download the installer
wget -O machine-status-unified-installer.sh https://example.com/machine-status-unified-installer.sh
chmod +x machine-status-unified-installer.sh

# Run the installer in server mode
sudo ./machine-status-unified-installer.sh server
```

#### Client Setup (Publisher only)

```bash
# Download the installer
wget -O machine-status-unified-installer.sh https://example.com/machine-status-unified-installer.sh
chmod +x machine-status-unified-installer.sh

# Run the installer in client mode, specifying the server IP
sudo ./machine-status-unified-installer.sh client --ip=192.168.1.100
```

### Advanced Installation Options

```bash
# Server with custom MQTT port and offline threshold
sudo ./machine-status-unified-installer.sh server --port=8883 --offline-threshold=30

# Client with custom publishing interval
sudo ./machine-status-unified-installer.sh client --ip=192.168.1.100 --interval=10
```

## Using the Multi-Machine Subscriber

The `simple_multi_machine_subscriber.py` script provides a lightweight way to monitor multiple machines without requiring a database.

### Command Line Usage

```bash
# Basic usage (local broker)
python3 simple_multi_machine_subscriber.py

# Specify broker address and port
python3 simple_multi_machine_subscriber.py --broker 192.168.1.100 --port 1883

# With authentication
python3 simple_multi_machine_subscriber.py --broker 192.168.1.100 --username admin --password secret

# Configure thresholds
python3 simple_multi_machine_subscriber.py --offline-threshold 30 --update-interval 5
```

### Using as a Module in Your Code

```python
import simple_multi_machine_subscriber as monitor

# Start monitoring machines
subscriber = monitor.start_monitoring(
    broker_address='192.168.1.100',
    broker_port=1883,
    username='admin',
    password='secret',
    offline_threshold=30,
    update_interval=0  # Set to 0 to disable automatic console updates
)

# Get status of all machines
all_machines = monitor.get_machine_status()
for machine_id, data in all_machines.items():
    print(f"Machine: {data['hostname']}")
    print(f"Status: {data['online_status']}")
    print(f"CPU Usage: {data['cpu']['usage_percent']}%")

# Get status of a specific machine
machine_data = monitor.get_machine_status('specific-machine-id')
if machine_data:
    print(f"Machine {machine_data['hostname']} is {machine_data['online_status']}")

# When done, stop monitoring
subscriber.stop()
```

### Integration Example: Real-time Dashboard

```python
import simple_multi_machine_subscriber as monitor
import time

# Start monitoring in the background (no console updates)
subscriber = monitor.start_monitoring(update_interval=0)

try:
    while True:
        # Get current machine statuses
        machines = monitor.get_machine_status()
        
        # Clear screen
        print("\033c", end="")
        
        # Print header
        print("==== REAL-TIME MACHINE MONITORING ====")
        print(f"Monitoring {len(machines)} machines")
        print("Last update:", time.strftime("%H:%M:%S"))
        print("=" * 40)
        
        # Print machines sorted by status (online first)
        sorted_machines = sorted(
            machines.items(), 
            key=lambda x: (0 if x[1]['online_status'] == 'online' else 1, x[1]['hostname'])
        )
        
        for machine_id, data in sorted_machines:
            status_marker = "✓" if data['online_status'] == 'online' else "✗"
            print(f"{status_marker} {data['hostname']} - CPU: {data['cpu']['usage_percent']:.1f}%")
        
        # Wait 2 seconds before next update
        time.sleep(2)
        
except KeyboardInterrupt:
    subscriber.stop()
```

## Web Dashboard

After installing the server components, you can access the web dashboard at:

```
http://<server-ip>:5000
```

The dashboard provides:
- Overview of all monitored machines
- Detailed statistics for each machine
- Historical data visualization
- Online/offline status tracking

## Troubleshooting

### Publisher Issues

If the publisher is not sending data:

1. Check MQTT connection settings:
   ```bash
   sudo cat /etc/machine-status/mqtt.env
   ```

2. Verify the service is running:
   ```bash
   sudo systemctl status machine-status-publisher
   ```

3. Check logs for errors:
   ```bash
   sudo journalctl -u machine-status-publisher -f
   ```

### Subscriber Issues

If the subscriber is not receiving data:

1. Check MQTT broker status:
   ```bash
   sudo systemctl status mosquitto
   ```

2. Verify the subscriber service:
   ```bash
   sudo systemctl status machine-status-subscriber
   ```

3. Check logs for errors:
   ```bash
   sudo journalctl -u machine-status-subscriber -f
   ```

## Architecture

```
[Client Machines]    →    [MQTT Broker]    →    [Subscriber]    →    [PostgreSQL]    →    [Web Dashboard]
    Publisher               (Mosquitto)         (Processes)          (Storage)           (Visualization)
```

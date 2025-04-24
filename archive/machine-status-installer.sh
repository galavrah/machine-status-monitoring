memory_total=machine_info.get('memory', {}).get('total', 'Unknown'),
                memory_available=machine_info.get('memory', {}).get('available', 'Unknown'),
                memory_usage=machine_info.get('memory', {}).get('usage_percent', 0),
                storage_total=machine_info.get('storage', {}).get('total', 'Unknown'),
                storage_free=machine_info.get('storage', {}).get('free', 'Unknown'),
                storage_usage=machine_info.get('storage', {}).get('usage_percent', 0),
                online_status=machine_info.get('online_status', 'online'),
                last_seen=datetime.now()
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
            logging.info(f"Starting MQTT Machine Status Subscriber with {self.offline_threshold}s offline threshold")
            self.client.loop_forever()
        
        except Exception as e:
            logging.error(f"Fatal error in subscriber: {e}")
        finally:
            # Clean up
            self.running = False
            if self.offline_detector_thread.is_alive():
                self.offline_detector_thread.join(timeout=1)
            self.client.disconnect()

def main():
    # Load configuration from environment files
    mqtt_config = {}
    db_config = {}
    
    # Load MQTT configuration
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        try:
            with open(mqtt_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        mqtt_config[key] = value
        except Exception as e:
            logging.error(f"Error reading MQTT config: {e}")
    
    # Load Database configuration
    db_config_file = '/etc/machine-status/db.env'
    if os.path.exists(db_config_file):
        try:
            with open(db_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        db_config[key] = value
        except Exception as e:
            logging.error(f"Error reading database config: {e}")
    
    # Get offline threshold from environment or use default (10 seconds)
    offline_threshold = int(os.getenv('OFFLINE_THRESHOLD', mqtt_config.get('OFFLINE_THRESHOLD', 10)))
    
    # If no database URL is found, prompt for it
    database_url = db_config.get('DATABASE_URL')
    if not database_url:
        print("No database configuration found. Please enter database credentials:")
        db_user = input("Database username: ")
        db_pass = input("Database password: ")
        db_name = input("Database name [machine_status_db]: ") or "machine_status_db"
        db_host = input("Database host [localhost]: ") or "localhost"
        database_url = f"postgresql://{db_user}:{db_pass}@{db_host}/{db_name}"

    # Create and run subscriber
    subscriber = MachineStatusSubscriber(
        broker_address=mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost'),
        broker_port=int(mqtt_config.get('MQTT_BROKER_PORT', 1883)),
        username=mqtt_config.get('MQTT_USERNAME', ''),
        password=mqtt_config.get('MQTT_PASSWORD', ''),
        database_url=database_url,
        offline_threshold=offline_threshold
    )
    
    # Run the subscriber
    subscriber.run()

if __name__ == "__main__":
    main()
SUBSCRIBER_SCRIPT

    # Set correct permissions
    sudo chmod +x /opt/machine-status/subscriber/machine_status_subscriber.py
    
    # Create systemd service for subscriber
    sudo tee /etc/systemd/system/machine-status-subscriber.service > /dev/null <<EOL
[Unit]
Description=Machine Status MQTT Subscriber
After=network.target mosquitto.service postgresql.service

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/machine-status/mqtt.env
EnvironmentFile=-/etc/machine-status/db.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/subscriber/machine_status_subscriber.py
Restart=on-failure
RestartSec=10
WorkingDirectory=/opt/machine-status
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-subscriber
    sudo systemctl start machine-status-subscriber
    
    log "Enhanced Machine Status Subscriber installed with online/offline detection"
    log "Offline threshold set to ${OFFLINE_THRESHOLD:-10} seconds"
}

# Install web dashboard
install_web_dashboard() {
    log "Installing Machine Status Web Dashboard..."
    
    # Create dashboard directory
    sudo mkdir -p /opt/machine-status/dashboard/templates
    sudo mkdir -p /opt/machine-status/dashboard/static/css
    
    # Create dashboard application
    sudo tee /opt/machine-status/dashboard/app.py > /dev/null <<'DASHBOARD_SCRIPT'
#!/usr/bin/env python3

import os
import json
import datetime
from typing import List, Dict, Any

from flask import Flask, render_template, jsonify, request, redirect, url_for
import sqlalchemy as sa
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy.sql import func

# Create Flask app
app = Flask(__name__)

# SQLAlchemy setup
Base = declarative_base()

class MachineStatus(Base):
    """Database model matching the one in the subscriber"""
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
    online_status = sa.Column(sa.String(20), default='unknown')
    last_seen = sa.Column(sa.DateTime, server_default=sa.func.now())
    timestamp = sa.Column(sa.DateTime, server_default=sa.func.now())

# Database connection
def get_db_session():
    """Create and return a database session"""
    # Load database URL from environment or config file
    db_url = os.getenv('DATABASE_URL')
    
    # If not found in environment, try to load from file
    if not db_url:
        db_config_file = '/etc/machine-status/db.env'
        if os.path.exists(db_config_file):
            with open(db_config_file, 'r') as f:
                for line in f:
                    if '=' in line and line.startswith('DATABASE_URL'):
                        _, db_url = line.strip().split('=', 1)
                        break
    
    # If still not found, use default
    if not db_url:
        db_url = 'postgresql://machine_status_user:password@localhost/machine_status_db'
    
    # Create engine and session
    engine = sa.create_engine(db_url)
    Session = sessionmaker(bind=engine)
    return Session()

def get_machine_list() -> List[Dict[str, Any]]:
    """Get list of all known machines with their latest status"""
    session = get_db_session()
    try:
        # Use a CTE to get the latest record for each machine
        latest_records = session.query(
            MachineStatus.machine_id,
            func.max(MachineStatus.timestamp).label('max_timestamp')
        ).group_by(MachineStatus.machine_id).cte('latest_records')
        
        # Join with the main table to get the full records
        query = session.query(MachineStatus).join(
            latest_records,
            sa.and_(
                MachineStatus.machine_id == latest_records.c.machine_id,
                MachineStatus.timestamp == latest_records.c.max_timestamp
            )
        ).order_by(MachineStatus.hostname)
        
        machines = []
        for record in query:
            # Calculate time since last seen
            if record.last_seen:
                time_diff = datetime.datetime.now() - record.last_seen
                last_seen_mins = time_diff.total_seconds() / 60
                if last_seen_mins < 1:
                    last_seen = f"{int(time_diff.total_seconds())} seconds ago"
                else:
                    last_seen = f"{int(last_seen_mins)} minutes ago"
            else:
                last_seen = "Unknown"
            
            machines.append({
                'machine_id': record.machine_id,
                'hostname': record.hostname,
                'ip_address': record.ip_address,
                'cpu_usage': f"{record.cpu_usage:.1f}%" if record.cpu_usage is not None else "N/A",
                'memory_usage': f"{record.memory_usage:.1f}%" if record.memory_usage is not None else "N/A",
                'storage_usage': f"{record.storage_usage:.1f}%" if record.storage_usage is not None else "N/A",
                'online_status': record.online_status or 'unknown',
                'last_seen': last_seen,
                'timestamp': record.timestamp.strftime('%Y-%m-%d %H:%M:%S') if record.timestamp else "Unknown"
            })
        
        return machines
    finally:
        session.close()

def get_machine_details(machine_id: str) -> Dict[str, Any]:
    """Get detailed information about a specific machine"""
    session = get_db_session()
    try:
        # Get the latest record for this machine
        record = session.query(MachineStatus)\
            .filter(MachineStatus.machine_id == machine_id)\
            .order_by(MachineStatus.timestamp.desc())\
            .first()
        
        if not record:
            return None
            
        # Calculate time since last seen
        if record.last_seen:
            time_diff = datetime.datetime.now() - record.last_seen
            last_seen_mins = time_diff.total_seconds() / 60
            if last_seen_mins < 1:
                last_seen = f"{int(time_diff.total_seconds())} seconds ago"
            else:
                last_seen = f"{int(last_seen_mins)} minutes ago"
        else:
            last_seen = "Unknown"
        
        # Get history for charts (last 24 hours)
        history_query = session.query(MachineStatus)\
            .filter(MachineStatus.machine_id == machine_id)\
            .filter(MachineStatus.timestamp >= datetime.datetime.now() - datetime.timedelta(hours=24))\
            .order_by(MachineStatus.timestamp.asc())
            
        cpu_history = []
        memory_history = []
        storage_history = []
        timestamps = []
        
        for hist_record in history_query:
            if hist_record.cpu_usage is not None:
                cpu_history.append(hist_record.cpu_usage)
                memory_history.append(hist_record.memory_usage)
                storage_history.append(hist_record.storage_usage)
                timestamps.append(hist_record.timestamp.strftime('%H:%M'))
        
        return {
            'machine_id': record.machine_id,
            'hostname': record.hostname,
            'ip_address': record.ip_address,
            'cpu_model': record.cpu_model,
            'cpu_cores': record.cpu_cores,
            'cpu_usage': record.cpu_usage,
            'memory_total': record.memory_total,
            'memory_available': record.memory_available,
            'memory_usage': record.memory_usage,
            'storage_total': record.storage_total,
            'storage_free': record.storage_free,
            'storage_usage': record.storage_usage,
            'online_status': record.online_status or 'unknown',
            'last_seen': last_seen,
            'timestamp': record.timestamp.strftime('%Y-%m-%d %H:%M:%S') if record.timestamp else "Unknown",
            'history': {
                'timestamps': timestamps,
                'cpu_history': cpu_history,
                'memory_history': memory_history,
                'storage_history': storage_history
            }
        }
    finally:
        session.close()

# Flask routes
@app.route('/')
def index():
    """Main dashboard page"""
    machines = get_machine_list()
    return render_template('index.html', machines=machines)

@app.route('/api/machines')
def api_machines():
    """API endpoint for machine list"""
    machines = get_machine_list()
    return jsonify(machines)

@app.route('/api/machine/<machine_id>')
def api_machine_details(machine_id):
    """API endpoint for machine details"""
    details = get_machine_details(machine_id)
    if details:
        return jsonify(details)
    return jsonify({'error': 'Machine not found'}), 404

@app.route('/machine/<machine_id>')
def machine_details(machine_id):
    """Machine details page"""
    details = get_machine_details(machine_id)
    if details:
        return render_template('machine_details.html', machine=details)
    return "Machine not found", 404

if __name__ == '__main__':
    # Get environment variables or use defaults
    host = os.getenv('HOST', '0.0.0.0')
    port = int(os.getenv('PORT', 5000))
    debug = os.getenv('DEBUG', 'False').lower() in ('true', '1', 't')
    
    # Start the Flask app
    app.run(host=host, port=port, debug=debug)
DASHBOARD_SCRIPT

    # Create base template
    sudo tee /opt/machine-status/dashboard/templates/base.html > /dev/null <<'BASE_TEMPLATE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}Machine Status Monitoring{% endblock %}</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/css/bootstrap.min.css">
    <link rel="stylesheet" href="{{ url_for('static', filename='css/styles.css') }}">
    {% block extra_css %}{% endblock %}
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-dark">
        <div class="container">
            <a class="navbar-brand" href="/">Machine Status Monitoring</a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav">
                    <li class="nav-item">
                        <a class="nav-link" href="/">Dashboard</a>
                    </li>
                </ul>
            </div>
        </div>
    </nav>

    <div class="container mt-4">
        {% block content %}{% endblock %}
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@3.7.1/dist/chart.min.js"></script>
    {% block extra_js %}{% endblock %}
</body>
</html>
BASE_TEMPLATE

    # Create index template
    sudo tee /opt/machine-status/dashboard/templates/index.html > /dev/null <<'INDEX_TEMPLATE'
{% extends 'base.html' %}

{% block title %}Dashboard - Machine Status Monitoring{% endblock %}

{% block content %}
<h1 class="mb-4">Machine Status Dashboard</h1>

<div class="row mb-4">
    <div class="col-md-3">
        <div class="card text-white bg-success">
            <div class="card-body">
                <h5 class="card-title">Online Machines</h5>
                <h2 class="card-text">{{ machines|selectattr('online_status', 'equalto', 'online')|list|length }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card text-white bg-danger">
            <div class="card-body">
                <h5 class="card-title">Offline Machines</h5>
                <h2 class="card-text">{{ machines|selectattr('online_status', 'equalto', 'offline')|list|length }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card text-white bg-secondary">
            <div class="card-body">
                <h5 class="card-title">Unknown Status</h5>
                <h2 class="card-text">{{ machines|rejectattr('online_status', 'in', ['online', 'offline'])|list|length }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card text-white bg-primary">
            <div class="card-body">
                <h5 class="card-title">Total Machines</h5>
                <h2 class="card-text">{{ machines|length }}</h2>
            </div>
        </div>
    </div>
</div>

<div class="card mb-4">
    <div class="card-header d-flex justify-content-between align-items-center">
        <h5 class="mb-0">Machine List</h5>
        <button class="btn btn-sm btn-primary" id="refreshBtn">Refresh</button>
    </div>
    <div class="card-body">
        <div class="table-responsive">
            <table class="table table-striped table-hover">
                <thead>
                    <tr>
                        <th>Status</th>
                        <th>Hostname</th>
                        <th>IP Address</th>
                        <th>CPU Usage</th>
                        <th>Memory Usage</th>
                        <th>Storage Usage</th>
                        <th>Last Seen</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody id="machineTableBody">
                    {% for machine in machines %}
                    <tr>
                        <td>
                            {% if machine.online_status == 'online' %}
                            <span class="badge bg-success">Online</span>
                            {% elif machine.online_status == 'offline' %}
                            <span class="badge bg-danger">Offline</span>
                            {% else %}
                            <span class="badge bg-secondary">Unknown</span>
                            {% endif %}
                        </td>
                        <td>{{ machine.hostname }}</td>
                        <td>{{ machine.ip_address }}</td>
                        <td>{{ machine.cpu_usage }}</td>
                        <td>{{ machine.memory_usage }}</td>
                        <td>{{ machine.storage_usage }}</td>
                        <td>{{ machine.last_seen }}</td>
                        <td>
                            <a href="/machine/{{ machine.machine_id }}" class="btn btn-sm btn-info">Details</a>
                        </td>
                    </tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>
    </div>
</div>
{% endblock %}

{% block extra_js %}
<script>
document.getElementById('refreshBtn').addEventListener('click', function() {
    fetch('/api/machines')
        .then(response => response.json())
        .then(machines => {
            const tableBody = document.getElementById('machineTableBody');
            tableBody.innerHTML = '';
            
            machines.forEach(machine => {
                let statusBadge = '';
                if (machine.online_status === 'online') {
                    statusBadge = '<span class="badge bg-success">Online</span>';
                } else if (machine.online_status === 'offline') {
                    statusBadge = '<span class="badge bg-danger">Offline</span>';
                } else {
                    statusBadge = '<span class="badge bg-secondary">Unknown</span>';
                }
                
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${statusBadge}</td>
                    <td>${machine.hostname}</td>
                    <td>${machine.ip_address}</td>
                    <td>${machine.cpu_usage}</td>
                    <td>${machine.memory_usage}</td>
                    <td>${machine.storage_usage}</td>
                    <td>${machine.last_seen}</td>
                    <td>
                        <a href="/machine/${machine.machine_id}" class="btn btn-sm btn-info">Details</a>
                    </td>
                `;
                tableBody.appendChild(row);
            });
            
            // Update dashboard counters
            const online = machines.filter(m => m.online_status === 'online').length;
            const offline = machines.filter(m => m.online_status === 'offline').length;
            const unknown = machines.filter(m => m.online_status !== 'online' && m.online_status !== 'offline').length;
            const total = machines.length;
            
            document.querySelectorAll('.card-text')[0].textContent = online;
            document.querySelectorAll('.card-text')[1].textContent = offline;
            document.querySelectorAll('.card-text')[2].textContent = unknown;
            document.querySelectorAll('.card-text')[3].textContent = total;
        });
});

// Auto-refresh every 10 seconds
setInterval(function() {
    document.getElementById('refreshBtn').click();
}, 10000);
</script>
{% endblock %}
INDEX_TEMPLATE

    # Create machine details template
    sudo tee /opt/machine-status/dashboard/templates/machine_details.html > /dev/null <<'DETAILS_TEMPLATE'
{% extends 'base.html' %}

{% block title %}{{ machine.hostname }} - Machine Status{% endblock %}

{% block content %}
<div class="d-flex justify-content-between align-items-center mb-4">
    <h1>
        {{ machine.hostname }}
        {% if machine.online_status == 'online' %}
        <span class="badge bg-success">Online</span>
        {% elif machine.online_status == 'offline' %}
        <span class="badge bg-danger">Offline</span>
        {% else %}
        <span class="badge bg-secondary">Unknown</span>
        {% endif %}
    </h1>
    <div>
        <a href="/" class="btn btn-secondary">Back to Dashboard</a>
        <button id="refreshBtn" class="btn btn-primary">Refresh</button>
    </div>
</div>

<div class="row mb-4">
    <div class="col-md-6">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">System Information</h5>
            </div>
            <div class="card-body">
                <table class="table">
                    <tr>
                        <th>Machine ID:</th>
                        <td>{{ machine.machine_id }}</td>
                    </tr>
                    <tr>
                        <th>Hostname:</th>
                        <td>{{ machine.hostname }}</td>
                    </tr>
                    <tr>
                        <th>IP Address:</th>
                        <td>{{ machine.ip_address }}</td>
                    </tr>
                    <tr>
                        <th>Status:</th>
                        <td>
                            {% if machine.online_status == 'online' %}
                            <span class="badge bg-success">Online</span>
                            {% elif machine.online_status == 'offline' %}
                            <span class="badge bg-danger">Offline</span>
                            {% else %}
                            <span class="badge bg-secondary">Unknown</span>
                            {% endif %}
                        </td>
                    </tr>
                    <tr>
                        <th>Last Seen:</th>
                        <td>{{ machine.last_seen }}</td>
                    </tr>
                    <tr>
                        <th>Last Updated:</th>
                        <td>{{ machine.timestamp }}</td>
                    </tr>
                </table>
            </div>
        </div>
    </div>
    
    <div class="col-md-6">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Hardware Information</h5>
            </div>
            <div class="card-body">
                <table class="table">
                    <tr>
                        <th>CPU Model:</th>
                        <td>{{ machine.cpu_model }}</td>
                    </tr>
                    <tr>
                        <th>CPU Cores:</th>
                        <td>{{ machine.cpu_cores }}</td>
                    </tr>
                    <tr>
                        <th>Memory Total:</th>
                        <td>{{ machine.memory_total }}</td>
                    </tr>
                    <tr>
                        <th>Memory Available:</th>
                        <td>{{ machine.memory_available }}</td>
                    </tr>
                    <tr>
                        <th>Storage Total:</th>
                        <td>{{ machine.storage_total }}</td>
                    </tr>
                    <tr>
                        <th>Storage Free:</th>
                        <td>{{ machine.storage_free }}</td>
                    </tr>
                </table>
            </div>
        </div>
    </div>
</div>

<div class="row mb-4">
    <div class="col-md-4">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">CPU Usage</h5>
            </div>
            <div class="card-body">
                <div class="d-flex justify-content-center">
                    <div class="gauge-container">
                        <canvas id="cpuGauge"></canvas>
                        <div class="gauge-value" id="cpuValue">{{ "%.1f"|format(machine.cpu_usage) }}%</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
    
    <div class="col-md-4">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Memory Usage</h5>
            </div>
            <div class="card-body">
                <div class="d-flex justify-content-center">
                    <div class="gauge-container">
                        <canvas id="memoryGauge"></canvas>
                        <div class="gauge-value" id="memoryValue">{{ "%.1f"|format(machine.memory_usage) }}%</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
    
    <div class="col-md-4">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Storage Usage</h5>
            </div>
            <div class="card-body">
                <div class="d-flex justify-content-center">
                    <div class="gauge-container">
                        <canvas id="storageGauge"></canvas>
                        <div class="gauge-value" id="storageValue">{{ "%.1f"|format(machine.storage_usage) }}%</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<div class="card mb-4">
    <div class="card-header">
        <h5 class="mb-0">Historical Data (Last 24 Hours)</h5>
    </div>
    <div class="card-body">
        <canvas id="historyChart"></canvas>
    </div>
</div>
{% endblock %}

{% block extra_css %}
<style>
.gauge-container {
    position: relative;
    width: 200px;
    height: 200px;
}
.gauge-value {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    font-size: 24px;
    font-weight: bold;
}
</style>
{% endblock %}

{% block extra_js %}
<script>
function createGauge(elementId, value, label, color) {
    const ctx = document.getElementById(elementId).getContext('2d');
    return new Chart(ctx, {
        type: 'doughnut',
        data: {
            datasets: [{
                data: [value, 100 - value],
                backgroundColor: [color, '#e9ecef'],
                borderWidth: 0
            }]
        },
        options: {
            cutout: '75%',
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: { display: false },
                tooltip: { enabled: false }
            }
        }
    });
}

// Create gauges
const cpuGauge = createGauge('cpuGauge', {{ machine.cpu_usage or 0 }}, 'CPU', '#dc3545');
const memoryGauge = createGauge('memoryGauge', {{ machine.memory_usage or 0 }}, 'Memory', '#fd7e14');
const storageGauge = createGauge('storageGauge',#!/bin/bash

# Machine Status Monitoring System Unified Installer
# Usage: sudo ./machine-status-installer.sh [server|client] [options]

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INSTALLER]${NC} $1"
}

# Warning function
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Error handling function
error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Get input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local input
    
    echo -n -e "${prompt} [${default}]: "
    read input
    echo "${input:-$default}"
}

# Detect Linux distribution
detect_distribution() {
    # Check if /etc/os-release exists (standard for modern Linux distributions)
    if [ -f /etc/os-release ]; then
        # Source the file to get distribution information
        . /etc/os-release
        
        # Set distribution variables
        DISTRO=$ID          # e.g., ubuntu, fedora, debian
        DISTRO_VERSION=$VERSION_ID  # e.g., 20.04, 22.04
        
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    else
        # Fallback for older systems
        if [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            DISTRO=$DISTRIB_ID
            DISTRO_VERSION=$DISTRIB_RELEASE
        elif [ -f /etc/redhat-release ]; then
            DISTRO=$(cat /etc/redhat-release | cut -d' ' -f1)
            DISTRO_VERSION=$(cat /etc/redhat-release | cut -d' ' -f3)
        else
            error "Unable to detect Linux distribution"
            return 1
        fi
        
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    fi
    
    # Export variables for use in other functions
    export DISTRO
    export DISTRO_VERSION
}

# Install common dependencies
install_common_dependencies() {
    log "Installing common dependencies..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pip python3-venv build-essential openssl curl
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf update -y
        sudo dnf install -y python3 python3-pip openssl curl
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    # Create Python virtual environment
    sudo mkdir -p /opt/machine-status
    sudo python3 -m venv /opt/machine-status/venv
    
    log "Common dependencies installed"
}

# Install Python dependencies
install_python_dependencies() {
    log "Installing Python dependencies..."
    
    # Update pip
    sudo /opt/machine-status/venv/bin/pip install --upgrade pip
    
    # Install required packages for client
    if [ "$1" = "client" ]; then
        sudo /opt/machine-status/venv/bin/pip install paho-mqtt psutil
    fi
    
    # Install required packages for server
    if [ "$1" = "server" ]; then
        sudo /opt/machine-status/venv/bin/pip install paho-mqtt psutil sqlalchemy psycopg2-binary flask
    fi
    
    log "Python dependencies installed"
}

# Install MQTT Broker
install_mqtt_broker() {
    log "Installing MQTT Broker (Mosquitto)..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y mosquitto mosquitto-clients
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y mosquitto
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    log "MQTT Broker installed"
}

# Configure MQTT Broker
configure_mqtt_broker() {
    log "Configuring MQTT Broker..."
    
    # Generate MQTT credentials
    MQTT_USER="${MQTT_USERNAME:-machine_status}"
    MQTT_PASS="${MQTT_PASSWORD:-$(openssl rand -base64 12)}"
    
    # Create configuration directory
    sudo mkdir -p /etc/machine-status
    
    # Store MQTT credentials in environment file
    sudo tee /etc/machine-status/mqtt.env > /dev/null <<EOL
MQTT_BROKER_ADDRESS=${MQTT_BROKER_ADDRESS}
MQTT_BROKER_PORT=${MQTT_BROKER_PORT:-1883}
MQTT_USERNAME=${MQTT_USER}
MQTT_PASSWORD=${MQTT_PASS}
PUBLISH_INTERVAL=${PUBLISH_INTERVAL:-5}
OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-10}
EOL
    sudo chmod 600 /etc/machine-status/mqtt.env
    
    # Configure Mosquitto
    sudo tee /etc/mosquitto/conf.d/machine-status.conf > /dev/null <<EOL
# Machine Status MQTT Configuration
listener ${MQTT_BROKER_PORT:-1883}
allow_anonymous true
EOL

    # Create MQTT user and password
    sudo touch /etc/mosquitto/passwd
    sudo mosquitto_passwd -b /etc/mosquitto/passwd "${MQTT_USER}" "${MQTT_PASS}"
    
    # Restart Mosquitto
    sudo systemctl restart mosquitto
    sudo systemctl enable mosquitto
    
    log "MQTT Broker configured with username: ${MQTT_USER} and password: ${MQTT_PASS}"
    log "Credential file: /etc/machine-status/mqtt.env"
}

# Install PostgreSQL
install_postgresql() {
    log "Installing PostgreSQL..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y postgresql postgresql-contrib
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y postgresql postgresql-server postgresql-contrib
        sudo postgresql-setup --initdb --unit postgresql
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    log "PostgreSQL installed"
}

# Configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL..."
    
    # Use provided credentials or generate random ones
    DB_NAME="${DB_NAME:-machine_status_db}"
    DB_USER="${DB_USER:-machine_status_user}"
    
    # If no password provided, generate one
    if [ -z "${DB_PASS}" ]; then
        DB_PASS=$(openssl rand -base64 12)
    fi
    
    # Create database and user
    sudo -u postgres psql <<POSTGRESQL_SCRIPT
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
POSTGRESQL_SCRIPT
    
    # Store credentials securely
    sudo mkdir -p /etc/machine-status
    sudo tee /etc/machine-status/db.env > /dev/null <<EOL
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}
EOL
    sudo chmod 600 /etc/machine-status/db.env
    
    log "PostgreSQL configured with:"
    log "  Database: ${DB_NAME}"
    log "  Username: ${DB_USER}"
    log "  Password: ${DB_PASS}"
    log "  Credential file: /etc/machine-status/db.env"
}

# Install Machine Status Publisher with 5-second interval and offline detection
install_machine_status_publisher() {
    log "Installing Enhanced Machine Status Publisher (5-second interval)..."
    
    # Create installation directory and ensure log directory exists
    sudo mkdir -p /opt/machine-status/publisher
    sudo mkdir -p /var/log
    sudo touch /var/log/machine-status-publisher.log
    sudo chmod 644 /var/log/machine-status-publisher.log
    
    # Create machine ID directory
    sudo mkdir -p /etc/machine-status
    
    # Copy publisher script
    sudo tee /opt/machine-status/publisher/machine_status_publisher.py > /dev/null <<'PUBLISHER_SCRIPT'
#!/usr/bin/env python3

import os
import json
import time
import socket
import logging
import uuid
import platform
import subprocess
from typing import Dict, Any

import paho.mqtt.client as mqtt
import psutil

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-publisher.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class MachineStatusPublisher:
    def __init__(
        self, 
        mqtt_broker_address: str = 'localhost', 
        mqtt_broker_port: int = 1883, 
        mqtt_username: str = '', 
        mqtt_password: str = None,
        machine_id: str = None,
        publish_interval: int = 5  # Default to 5 seconds
    ):
        """
        Initialize MQTT Machine Status Publisher
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = mqtt_broker_address
        self.broker_port = mqtt_broker_port
        
        # Set up MQTT authentication
        if mqtt_username and mqtt_password:
            self.client.username_pw_set(mqtt_username, mqtt_password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        
        # Machine identification
        self.machine_id = machine_id or self._generate_machine_id()
        self.publish_interval = publish_interval
        
        # Add Will message for offline status
        self.client.will_set(
            f"machine_status/{self.machine_id}/status",
            json.dumps({"status": "offline", "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())}),
            qos=1,
            retain=True
        )
        
        logging.info(f"Initialized Machine Status Publisher with ID: {self.machine_id}, publish interval: {self.publish_interval}s")

    def _generate_machine_id(self) -> str:
        """
        Generate a unique machine ID or use existing one
        """
        # Check if machine ID already exists
        id_file = "/etc/machine-status/machine_id"
        if os.path.exists(id_file):
            with open(id_file, 'r') as f:
                return f.read().strip()
        
        # Generate new ID based on hostname and a random UUID
        machine_id = f"{socket.gethostname()}-{str(uuid.uuid4())}"
        
        # Save ID to file
        os.makedirs(os.path.dirname(id_file), exist_ok=True)
        with open(id_file, 'w') as f:
            f.write(machine_id)
        
        return machine_id

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        """
        if rc == 0:
            logging.info("Connected to MQTT Broker successfully")
            # Publish online status immediately on connect
            self._publish_status("online")
        else:
            logging.error(f"Failed to connect to MQTT Broker. Return code: {rc}")

    def _on_disconnect(self, client, userdata, rc):
        """
        MQTT disconnection callback
        """
        logging.warning(f"Disconnected from MQTT Broker. Return code: {rc}")
        # Attempt to reconnect
        try:
            client.reconnect()
        except Exception as e:
            logging.error(f"Reconnection failed: {e}")

    def _collect_system_info(self) -> Dict[str, Any]:
        """
        Collect system information
        """
        try:
            # Basic system info
            hostname = socket.gethostname()
            try:
                ip_address = socket.gethostbyname(hostname)
            except:
                ip_address = "Unable to determine IP"
            
            # CPU info
            cpu_usage = psutil.cpu_percent(interval=1)
            cpu_count = psutil.cpu_count(logical=True)
            
            # Try to get CPU model
            cpu_model = "Unknown"
            try:
                if platform.system() == "Linux":
                    with open('/proc/cpuinfo', 'r') as f:
                        for line in f:
                            if line.startswith('model name'):
                                cpu_model = line.split(':')[1].strip()
                                break
                else:
                    cpu_model = platform.processor()
            except Exception as e:
                logging.warning(f"Could not determine CPU model: {e}")
            
            # Memory info
            memory = psutil.virtual_memory()
            memory_total = self._format_bytes(memory.total)
            memory_available = self._format_bytes(memory.available)
            memory_usage_percent = memory.percent
            
            # Disk info
            disk = psutil.disk_usage('/')
            disk_total = self._format_bytes(disk.total)
            disk_free = self._format_bytes(disk.free)
            disk_usage_percent = disk.percent
            
            # Compile system info
            system_info = {
                "machine_id": self.machine_id,
                "hostname": hostname,
                "ip_address": ip_address,
                "cpu": {
                    "model": cpu_model,
                    "cores": cpu_count,
                    "usage_percent": cpu_usage
                },
                "memory": {
                    "total": memory_total,
                    "available": memory_available,
                    "usage_percent": memory_usage_percent
                },
                "storage": {
                    "total": disk_total,
                    "free": disk_free,
                    "usage_percent": disk_usage_percent
                },
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()),
                "status": "online"  # Include status in the main payload
            }
            
            return system_info
            
        except Exception as e:
            logging.error(f"Error collecting system information: {e}")
            return {"error": str(e), "machine_id": self.machine_id, "status": "error"}

    def _format_bytes(self, bytes_value: int) -> str:
        """
        Format bytes into human-readable format
        """
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"

    def _publish_status(self, status: str):
        """
        Publish machine status (online/offline)
        """
        try:
            status_payload = {
                "machine_id": self.machine_id,
                "status": status,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
            }
            
            json_payload = json.dumps(status_payload)
            
            result = self.client.publish(
                f"machine_status/{self.machine_id}/status", 
                json_payload, 
                qos=1,
                retain=True  # Use retain flag for status messages
            )
            
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                logging.info(f"Published status '{status}' successfully")
            else:
                logging.error(f"Failed to publish status. Error code: {result.rc}")
        
        except Exception as e:
            logging.error(f"Error publishing status: {e}")

    def publish_status(self):
        """
        Publish machine status to MQTT broker
        """
        try:
            # Collect system info
            system_info = self._collect_system_info()
            
            # Convert to JSON
            json_payload = json.dumps(system_info)
            
            # Publish to MQTT
            result = self.client.publish(
                f"machine_status/{self.machine_id}", 
                json_payload, 
                qos=1
            )
            
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                logging.info(f"Published status successfully")
            else:
                logging.error(f"Failed to publish status. Error code: {result.rc}")
                
        except Exception as e:
            logging.error(f"Error publishing machine status: {e}")

    def run(self):
        """
        Run the MQTT Machine Status Publisher
        """
        try:
            # Connect to MQTT Broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start MQTT loop in background thread
            self.client.loop_start()
            
            logging.info(f"Starting Machine Status Publisher with interval {self.publish_interval} seconds")
            
            # Main loop
            while True:
                self.publish_status()
                time.sleep(self.publish_interval)
                
        except KeyboardInterrupt:
            logging.info("Stopping Machine Status Publisher")
            self._publish_status("offline")
        except Exception as e:
            logging.error(f"Fatal error in publisher: {e}")
        finally:
            # Clean up
            self.client.loop_stop()
            self.client.disconnect()

def main():
    # Load configuration from environment file
    mqtt_config = {}
    
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        try:
            with open(mqtt_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        mqtt_config[key] = value
        except Exception as e:
            logging.error(f"Error reading MQTT config: {e}")
    
    # Get publish interval from environment or use default (5 seconds)
    publish_interval = int(os.getenv('PUBLISH_INTERVAL', mqtt_config.get('PUBLISH_INTERVAL', 5)))
    
    # Create and run publisher
    publisher = MachineStatusPublisher(
        mqtt_broker_address=mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost'),
        mqtt_broker_port=int(mqtt_config.get('MQTT_BROKER_PORT', 1883)),
        mqtt_username=mqtt_config.get('MQTT_USERNAME', ''),
        mqtt_password=mqtt_config.get('MQTT_PASSWORD', ''),
        publish_interval=publish_interval
    )
    
    # Run the publisher
    publisher.run()

if __name__ == "__main__":
    main()
PUBLISHER_SCRIPT

    # Set correct permissions
    sudo chmod +x /opt/machine-status/publisher/machine_status_publisher.py
    
    # Create systemd service for publisher
    sudo tee /etc/systemd/system/machine-status-publisher.service > /dev/null <<EOL
[Unit]
Description=Machine Status MQTT Publisher
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/machine-status/mqtt.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/publisher/machine_status_publisher.py
Restart=on-failure
RestartSec=10
WorkingDirectory=/opt/machine-status
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-publisher
    sudo systemctl start machine-status-publisher
    
    log "Enhanced Machine Status Publisher installed with 5-second interval and online/offline status"
}

# Install Machine Status Subscriber with multi-machine support and online/offline detection
install_machine_status_subscriber() {
    log "Installing Enhanced Machine Status Subscriber with online/offline tracking..."
    
    # Create installation directory and log file
    sudo mkdir -p /opt/machine-status/subscriber
    sudo mkdir -p /var/log
    sudo touch /var/log/machine-status-subscriber.log
    sudo chmod 644 /var/log/machine-status-subscriber.log
    
    # Copy subscriber script
    sudo tee /opt/machine-status/subscriber/machine_status_subscriber.py > /dev/null <<'SUBSCRIBER_SCRIPT'
#!/usr/bin/env python3

import os
import json
import time
import logging
import threading
from datetime import datetime, timedelta
from typing import Dict, Any

import paho.mqtt.client as mqtt
import sqlalchemy as sa
from sqlalchemy.orm import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.sql import func

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
    online_status = sa.Column(sa.String(20), default='unknown')
    last_seen = sa.Column(sa.DateTime, server_default=sa.func.now())
    timestamp = sa.Column(sa.DateTime, server_default=sa.func.now())

class MachineStatusSubscriber:
    def __init__(
        self, 
        broker_address: str = 'localhost', 
        broker_port: int = 1883, 
        username: str = '', 
        password: str = None,
        database_url: str = None,
        offline_threshold: int = 10  # Seconds before marking a machine as offline
    ):
        """
        Initialize MQTT Machine Status Subscriber
        
        :param broker_address: MQTT Broker address
        :param broker_port: MQTT Broker port
        :param username: MQTT Broker username
        :param password: MQTT Broker password
        :param database_url: SQLAlchemy database connection string
        :param offline_threshold: Time in seconds before a machine is considered offline
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = broker_address
        self.broker_port = broker_port
        self.offline_threshold = offline_threshold
        
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
        
        # Machine tracking dict to monitor online/offline status
        self.machines = {}
        
        # Start offline detection thread
        self.running = True
        self.offline_detector_thread = threading.Thread(target=self._offline_detector)
        self.offline_detector_thread.daemon = True
        self.offline_detector_thread.start()

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
            # Subscribe to machine status topics
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
            data = json.loads(payload)
            
            # Extract topic parts
            topic_parts = msg.topic.split('/')
            
            # Handle status-specific messages
            if len(topic_parts) >= 3 and topic_parts[2] == "status":
                machine_id = topic_parts[1]
                self._handle_status_message(machine_id, data)
                return
            
            # Handle regular machine status updates
            if 'machine_id' in data:
                # Update last seen timestamp and check online status
                machine_id = data.get('machine_id')
                self.machines[machine_id] = {
                    'last_seen': datetime.now(),
                    'status': data.get('status', 'online')
                }
                
                # Include online status in the data
                data['online_status'] = 'online'
                
                # Store in database
                self._store_machine_status(data)
                
                logging.info(f"Received status for machine {machine_id}")
            else:
                logging.warning(f"Received message without machine_id: {data}")
        
        except json.JSONDecodeError:
            logging.error(f"Failed to decode JSON from topic {msg.topic}")
        except Exception as e:
            logging.error(f"Error processing message: {e}")

    def _handle_status_message(self, machine_id: str, data: Dict):
        """
        Handle explicit status messages
        
        :param machine_id: Machine identifier
        :param data: Status message data
        """
        status = data.get('status', 'unknown')
        logging.info(f"Received explicit status '{status}' for machine {machine_id}")
        
        # Update machine status in tracking dict
        if machine_id not in self.machines:
            self.machines[machine_id] = {
                'last_seen': datetime.now(),
                'status': status
            }
        else:
            self.machines[machine_id]['status'] = status
            
            # If machine is coming online, update last_seen
            if status == 'online':
                self.machines[machine_id]['last_seen'] = datetime.now()
        
        # Update status in database
        self._update_machine_status(machine_id, status)

    def _offline_detector(self):
        """
        Background thread to detect offline machines
        """
        while self.running:
            now = datetime.now()
            offline_threshold = timedelta(seconds=self.offline_threshold)
            
            try:
                for machine_id, info in list(self.machines.items()):
                    # Skip machines that are already marked offline
                    if info['status'] == 'offline':
                        continue
                        
                    # Check if machine hasn't been seen recently
                    if now - info['last_seen'] > offline_threshold:
                        logging.info(f"Machine {machine_id} is offline (no data for {self.offline_threshold}s)")
                        self.machines[machine_id]['status'] = 'offline'
                        
                        # Update status in database
                        self._update_machine_status(machine_id, 'offline')
            except Exception as e:
                logging.error(f"Error in offline detector: {e}")
                
            # Sleep for a short time
            time.sleep(2)

    def _update_machine_status(self, machine_id: str, status: str):
        """
        Update machine online status in the database
        
        :param machine_id: Machine identifier
        :param status: Online status ('online', 'offline', etc.)
        """
        try:
            session = self.Session()
            
            # Find the latest record for this machine
            latest = session.query(MachineStatus)\
                .filter(MachineStatus.machine_id == machine_id)\
                .order_by(MachineStatus.timestamp.desc())\
                .first()
                
            if latest:
                # Update the status
                latest.online_status = status
                if status == 'online':
                    latest.last_seen = datetime.now()
                    
                session.commit()
                logging.info(f"Updated status for machine {machine_id} to {status}")
            else:
                logging.warning(f"No records found for machine {machine_id} to update status")
                
        except Exception as e:
            session.rollback()
            logging.error(f"Error updating machine status: {e}")
        finally:
            session.close()

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
                memory_available=machine_info.get('memory', {}).
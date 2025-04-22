#!/usr/bin/env python3
import os
from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSONB
from datetime import datetime
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/machine-status-server.log'),
        logging.StreamHandler()
    ]
)

# Create Flask application
app = Flask(__name__)

# Configure PostgreSQL Database
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv(
    'DATABASE_URL', 
    'postgresql://username:password@localhost/machine_status_db'
)
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# Initialize SQLAlchemy
db = SQLAlchemy(app)

class MachineStatus(db.Model):
    """
    Database model to store machine status information
    """
    __tablename__ = 'machine_statuses'

    id = db.Column(db.Integer, primary_key=True)
    machine_id = db.Column(db.String(255), nullable=False, index=True)
    hostname = db.Column(db.String(255), nullable=False)
    ip_address = db.Column(db.String(100))
    cpu_model = db.Column(db.String(255))
    memory = db.Column(db.String(50))
    storage_info = db.Column(JSONB)
    cpu_usage = db.Column(db.String(10))
    memory_usage = db.Column(db.String(10))
    timestamp = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    def to_dict(self):
        """
        Convert database record to dictionary
        """
        return {
            'id': self.id,
            'machine_id': self.machine_id,
            'hostname': self.hostname,
            'ip_address': self.ip_address,
            'cpu_model': self.cpu_model,
            'memory': self.memory,
            'storage_info': self.storage_info,
            'cpu_usage': self.cpu_usage,
            'memory_usage': self.memory_usage,
            'timestamp': self.timestamp.isoformat()
        }

@app.route('/machine-status', methods=['POST'])
def receive_machine_status():
    """
    Endpoint to receive machine status updates
    """
    try:
        # Get JSON data from request
        data = request.get_json()
        
        # Validate required fields
        if not data or 'machine_id' not in data:
            logging.warning("Invalid machine status payload received")
            return jsonify({"error": "Invalid payload"}), 400

        # Create new machine status record
        machine_status = MachineStatus(
            machine_id=data['machine_id'],
            hostname=data.get('hostname', 'Unknown'),
            ip_address=data.get('ip', ''),
            cpu_model=data.get('cpu_model', 'Unknown'),
            memory=data.get('memory', 'Unknown'),
            storage_info=data.get('storage', {}),
            cpu_usage=data.get('cpu_usage', 'Unknown'),
            memory_usage=data.get('memory_usage', 'Unknown')
        )

        # Add and commit to database
        db.session.add(machine_status)
        db.session.commit()

        logging.info(f"Received status for machine {data['machine_id']}")
        return jsonify({"status": "success"}), 200

    except Exception as e:
        # Rollback in case of error
        db.session.rollback()
        logging.error(f"Error processing machine status: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/machine-status', methods=['GET'])
def get_machine_statuses():
    """
    Endpoint to retrieve machine statuses
    
    Optional query parameters:
    - machine_id: Filter by specific machine
    - limit: Limit number of results (default 100)
    - offset: Offset for pagination (default 0)
    """
    try:
        # Get query parameters
        machine_id = request.args.get('machine_id')
        limit = int(request.args.get('limit', 100))
        offset = int(request.args.get('offset', 0))

        # Build query
        query = MachineStatus.query

        # Filter by machine_id if provided
        if machine_id:
            query = query.filter_by(machine_id=machine_id)

        # Order by timestamp (most recent first)
        query = query.order_by(MachineStatus.timestamp.desc())

        # Apply pagination
        statuses = query.limit(limit).offset(offset).all()

        # Convert to list of dictionaries
        return jsonify([status.to_dict() for status in statuses]), 200

    except Exception as e:
        logging.error(f"Error retrieving machine statuses: {e}")
        return jsonify({"error": "Internal server error"}), 500

def create_database():
    """
    Create database tables
    """
    with app.app_context():
        try:
            db.create_all()
            logging.info("Database tables created successfully")
        except Exception as e:
            logging.error(f"Error creating database tables: {e}")

def main():
    # Create database tables
    create_database()

    # Run the Flask application
    app.run(
        host='0.0.0.0',  # Listen on all network interfaces
        port=5000,       # Port to listen on
        debug=False      # Disable debug mode in production
    )

if __name__ == "__main__":
    main()
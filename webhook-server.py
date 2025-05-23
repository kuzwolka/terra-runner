#!/usr/bin/env python3

import http.server
import socketserver
import json
import subprocess
import os
import sys
import time
import threading
from urllib.parse import parse_qs, urlparse

PORT = 8080

class TerraformRequestHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/run-terraform':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            try:
                request = json.loads(post_data.decode('utf-8'))
                
                # Extract parameters
                project_name = request.get('project_name')
                command = request.get('command', 'plan')
                
                if not project_name:
                    self.send_error(400, "Missing project_name parameter")
                    return
                
                
                # Generate a unique run ID for the logs
                run_id = str(int(time.time()))
                
                # Run terraform in a separate thread
                threading.Thread(target=self.run_terraform, 
                                 args=(project_name, command)).start()
                
                # Send response
                self.send_response(202)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                response = {
                    'status': 'accepted',
                    'message': f'Terraform {command} for {project_name} started',
                    'run_id': run_id,
                    'log_file': f'/home/terraform/logs/terraform-{project_name}-{run_id}.log'
                }
                self.wfile.write(json.dumps(response).encode())
                
            except json.JSONDecodeError:
                self.send_error(400, "Invalid JSON in request body")
            except Exception as e:
                self.send_error(500, str(e))
        else:
            self.send_error(404, "Not found")
    
    def run_terraform(self, project_name, command):
        try:
            subprocess.run([
                '/opt/terraform-runner/run-terraform.sh',
                project_name,
                command,
            ], check=True)
        except subprocess.CalledProcessError as e:
            print(f"Error running Terraform: {e}", file=sys.stderr)
    
    def log_message(self, format, *args):
        # Override to add timestamp
        sys.stderr.write("%s - %s - %s\n" %
                         (self.log_date_time_string(),
                          self.address_string(),
                          format % args))

def run_server():
    with socketserver.TCPServer(("", PORT), TerraformRequestHandler) as httpd:
        print(f"Serving webhook at port {PORT}")
        httpd.serve_forever()

if __name__ == "__main__":
    run_server()
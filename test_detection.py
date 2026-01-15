#!/usr/bin/env python3
"""
Test script for recovery.sql and detect.sql detection procedures.
Runs cluster setup, crash scenario, and tests both detection procedures.
"""

import subprocess
import sys
import os
import time
import getpass

try:
    import psycopg2
    from psycopg2 import OperationalError
except ImportError:
    print("ERROR: psycopg2 is required. Install with: pip install psycopg2-binary")
    sys.exit(1)

# Configuration
DB_USER = getpass.getuser()
DB_NAME = "pgedge"
PORT_START = 5451

def run_command(cmd, check=True):
    """Run a command and return result."""
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"ERROR: Command failed with return code {result.returncode}")
        print(f"STDOUT: {result.stdout}")
        print(f"STDERR: {result.stderr}")
        return False
    return result.returncode == 0

def check_cluster_running():
    """Check if cluster nodes are running."""
    for i in range(3):
        port = PORT_START + i
        try:
            conn = psycopg2.connect(
                host="localhost",
                port=port,
                user=DB_USER,
                database=DB_NAME,
                connect_timeout=2
            )
            conn.close()
        except Exception:
            return False
    return True

def setup_cluster():
    """Setup the cluster using cluster.py."""
    print("\n=== Step 1: Setting up cluster ===")
    if check_cluster_running():
        print("Cluster is already running, skipping setup")
        return True
    
    cmd = ["python3", "cluster.py", "--port-start", str(PORT_START)]
    return run_command(cmd, check=False)

def run_crash_scenario():
    """Run crash scenario using cluster.py --crash."""
    print("\n=== Step 2: Running crash scenario ===")
    if not check_cluster_running():
        print("ERROR: Cluster is not running. Cannot run crash scenario.")
        return False
    
    cmd = ["python3", "cluster.py", "--crash", "--port-start", str(PORT_START)]
    result = run_command(cmd, check=False)
    # Crash scenario may exit with error when n1 crashes, which is expected
    return True

def test_detection_procedures():
    """Test both detection procedures."""
    print("\n=== Step 3: Testing detection procedures ===")
    
    source_dsn = f"host=localhost port={PORT_START + 1} dbname={DB_NAME} user={DB_USER}"
    target_dsn = f"host=localhost port={PORT_START + 2} dbname={DB_NAME} user={DB_USER}"
    
    # Connect to source node (n2)
    try:
        conn = psycopg2.connect(
            host="localhost",
            port=PORT_START + 1,
            user=DB_USER,
            database=DB_NAME,
            connect_timeout=5
        )
    except Exception as e:
        print(f"ERROR: Cannot connect to source node (n2): {e}")
        return False
    
    # Test recovery.sql (detect_lag)
    print("\n--- Testing recovery.sql (detect_lag) ---")
    try:
        # Load the procedure
        with open("recovery.sql", "r") as f:
            recovery_sql = f.read()
        
        with conn.cursor() as cur:
            cur.execute(recovery_sql)
            conn.commit()
            print("✓ recovery.sql loaded successfully")
        
        # Call the procedure
        with conn.cursor() as cur:
            cur.execute("""
                CALL spock.detect_lag(
                    failed_node_name := %s,
                    source_node_name := %s,
                    source_dsn := %s,
                    target_node_name := %s,
                    target_dsn := %s
                );
            """, ('n1', 'n2', source_dsn, 'n3', target_dsn))
            conn.commit()
            print("✓ detect_lag procedure executed successfully")
    except Exception as e:
        print(f"✗ recovery.sql test failed: {e}")
        import traceback
        traceback.print_exc()
        return False
    
    # Test detect.sql (detect_slot_lag)
    print("\n--- Testing detect.sql (detect_slot_lag) ---")
    try:
        # Load the procedure
        with open("detect.sql", "r") as f:
            detect_sql = f.read()
        
        with conn.cursor() as cur:
            cur.execute(detect_sql)
            conn.commit()
            print("✓ detect.sql loaded successfully")
        
        # Call the procedure
        with conn.cursor() as cur:
            cur.execute("""
                CALL spock.detect_slot_lag(
                    failed_node_name := %s,
                    source_node_name := %s,
                    source_dsn := %s,
                    target_node_name := %s,
                    target_dsn := %s
                );
            """, ('n1', 'n2', source_dsn, 'n3', target_dsn))
            conn.commit()
            print("✓ detect_slot_lag procedure executed successfully")
    except Exception as e:
        print(f"✗ detect.sql test failed: {e}")
        import traceback
        traceback.print_exc()
        return False
    
    conn.close()
    return True

def main():
    """Main test function."""
    print("=" * 70)
    print("Testing Detection Procedures")
    print("=" * 70)
    
    # Change to script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    
    # Step 1: Setup cluster
    if not setup_cluster():
        print("ERROR: Cluster setup failed")
        sys.exit(1)
    
    # Wait a bit for cluster to be ready
    print("Waiting for cluster to be ready...")
    for i in range(30):
        if check_cluster_running():
            break
        time.sleep(1)
    else:
        print("ERROR: Cluster did not become ready")
        sys.exit(1)
    
    # Step 2: Run crash scenario
    if not run_crash_scenario():
        print("WARNING: Crash scenario had issues, but continuing...")
    
    # Wait a bit after crash
    time.sleep(2)
    
    # Step 3: Test detection procedures
    if not test_detection_procedures():
        print("\nERROR: Detection procedure tests failed")
        sys.exit(1)
    
    print("\n" + "=" * 70)
    print("All tests completed successfully!")
    print("=" * 70)

if __name__ == "__main__":
    main()






#!/bin/bash
#------------------------------------------------------------------------------
# @description Test tls-cert-expiry checks: simulated and production certificates.
# @example cd csi-spl-utl && ./run -a do_test_tls_cert_expiry
#------------------------------------------------------------------------------
do_test_tls_cert_expiry() {
  local test_dir="/tmp/tls-cert-expiry-test"
  mkdir -p "$test_dir" || { echo "FATAL failed to create test dir: $test_dir"; return 1; }

  # Test 1: Simulate a certificate expiring in 14 days (WARNING)
  echo "Test 1: Simulate a certificate expiring in 14 days (WARNING)"
  openssl req -x509 -newkey rsa:2048 -keyout "$test_dir/key-warning.pem" -out "$test_dir/cert-warning.pem" \
    -days 14 -nodes -subj "/CN=test-warning.spool-hub.ai" 2>/dev/null || \
    { echo "FATAL failed to generate test certificate"; return 1; }

  # Mock openssl to return the test certificate
  mock_openssl() {
    echo "Mock openssl called"
    cat "$test_dir/cert.pem"
  }
  export -f mock_openssl
  export OPENSSL_CMD=mock_openssl

  # Mock spool-send.sh to avoid sending notes during tests
  export spool_messages=()
  mock_spool_send() {
    spool_messages+=("$*")
    echo "MOCK spool-send: $*"
    return 0
  }
  export -f mock_spool_send

  # Override spool-send.sh path
  local mock_dir="$test_dir/mock"
  mkdir -p "$mock_dir" || { echo "FATAL failed to create mock dir: $mock_dir"; return 1; }
  export PATH="$mock_dir:$PATH"
  echo '#!/bin/bash
mock_spool_send "$@"
' > "$mock_dir/spool-send.sh"
  chmod +x "$mock_dir/spool-send.sh"

  # Override SPOOL_SEND_PATH to use the mock
  export SPOOL_SEND_PATH="$mock_dir/spool-send.sh"

  # Use a temporary SPOOL_ROOT for the mock
  export SPOOL_ROOT="$test_dir/spool"

  # Override openssl
  echo '#!/bin/bash
if [[ "$*" == *"s_client"* ]]; then
  echo "Mock s_client output for: $*" >&2
  if [[ "$*" == *"test-warning.spool-hub.ai"* ]]; then
    cat "$test_dir/cert-warning.pem"
  elif [[ "$*" == *"test-critical.spool-hub.ai"* ]]; then
    cat "$test_dir/cert-critical.pem"
  else
    cat "$test_dir/cert-warning.pem"  # Default to warning for testing
  fi
elif [[ "$*" == *"x509"* && "$*" == *"-enddate"* ]]; then
  echo "Mock x509 -enddate for: $*" >&2
  if [[ "$*" == *"test-warning.spool-hub.ai"* ]]; then
    date -u -d "14 days" "+%b %d %H:%M:%S %Y GMT"
  elif [[ "$*" == *"test-critical.spool-hub.ai"* ]]; then
    date -u -d "3 days" "+%b %d %H:%M:%S %Y GMT"
  else
    date -u -d "63 days" "+%b %d %H:%M:%S %Y GMT"
  fi
else
  echo "Mock openssl called with: $*" >&2
  exit 1
fi
' > "$mock_dir/openssl"
  chmod +x "$mock_dir/openssl"

  # Run the check
  (cd /opt/csi/csi-spl-wt/m-307/csi-spl-utl && \
    TEST_HOSTS="test-warning.spool-hub.ai" \
    TEST_EXPIRY_DATE="$(date -u -d "14 days" "+%b %d %H:%M:%S %Y GMT")" \
    ./run -a do_net_cert_expiry_check 2>&1) | tee /tmp/test_output.log
  grep -q "WARN.*14 days" /tmp/test_output.log || \
    { echo "FAIL: Test 1 did not detect WARNING threshold"; cat /tmp/test_output.log; return 1; }


  # Test 2: Simulate a certificate expiring in 3 days (CRITICAL)
  echo "Test 2: Simulate a certificate expiring in 3 days (CRITICAL)"

  (cd /opt/csi/csi-spl-wt/m-307/csi-spl-utl && \
    TEST_HOSTS="test-critical.spool-hub.ai" \
    TEST_EXPIRY_DATE="$(date -u -d "3 days" "+%b %d %H:%M:%S %Y GMT")" \
    ./run -a do_net_cert_expiry_check 2>&1) | tee /tmp/test_output.log
  grep -q "CRITICAL.*[23] days" /tmp/test_output.log || \
    { echo "FAIL: Test 2 did not detect CRITICAL threshold"; cat /tmp/test_output.log; return 1; }


  # Test 3: Red control (63 days should send nothing)
  echo "Test 3: Red control (63 days should send nothing)"
  (cd /opt/csi/csi-spl-wt/m-307/csi-spl-utl && \
    TEST_HOSTS="test-63d.spool-hub.ai" \
    TEST_EXPIRY_DATE="$(date -u -d "63 days" "+%b %d %H:%M:%S %Y GMT")" \
    ./run -a do_net_cert_expiry_check 2>&1) | tee /tmp/test_output.log
  if grep -q "OK: All certificates are valid for more than 21 days" /tmp/test_output.log; then
    echo "PASS: Test 3 (red control) - 63-day cert sent nothing"
  else
    echo "FAIL: Test 3 did not pass red control"; cat /tmp/test_output.log; return 1;
  fi

  echo "PASS: All tests completed successfully"
  return 0
}
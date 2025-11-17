# Testing Guide

This document describes the testing strategy for k3s-nested-installer and how to prevent regressions.

## Table of Contents

1. [Testing Philosophy](#testing-philosophy)
2. [Test Levels](#test-levels)
3. [Running Tests](#running-tests)
4. [Bug Case Study: Registry Configuration](#bug-case-study-registry-configuration)
5. [CI/CD Integration](#cicd-integration)
6. [Adding New Tests](#adding-new-tests)

---

## Testing Philosophy

The k3s-nested-installer project uses a **multi-level testing approach**:

- **Unit Tests**: Test individual functions and manifest generation
- **Integration Tests**: Deploy actual instances in test clusters
- **Dry-Run Tests**: Validate generated manifests without deployment
- **Regression Tests**: Ensure fixed bugs stay fixed

All tests should be:
- **Automated**: Run in CI/CD pipeline
- **Fast**: Unit tests < 1 minute, integration tests < 5 minutes
- **Reliable**: No flaky tests
- **Comprehensive**: Cover happy paths AND edge cases

---

## Test Levels

### 1. Lint Tests (Shellcheck)

Validates bash script syntax and common issues.

```bash
# Install shellcheck
sudo apt-get install shellcheck

# Run on all scripts
find . -name "*.sh" | xargs shellcheck
```

### 2. Unit Tests

Test individual components without requiring a Kubernetes cluster.

**Registry Configuration Tests** (`tests/test-registry-config.sh`):
- ConfigMap generation
- File copy logic (with/without auth)
- Volume mounts
- Registry path prefixes
- Insecure registry configuration

```bash
# Run registry config tests
./tests/test-registry-config.sh
```

### 3. Dry-Run Tests

Generate manifests and validate structure without deployment.

```bash
# Basic validation
./install.sh --name test --dry-run > /tmp/manifest.yaml
kubectl apply --dry-run=client -f /tmp/manifest.yaml

# With private registry
./install.sh --name test --private-registry docker.local --dry-run > /tmp/manifest.yaml
```

### 4. Integration Tests

Deploy actual instances in a test cluster.

```bash
# Requires a Kubernetes cluster
export RUN_INTEGRATION_TESTS=true
./tests/test-registry-config.sh
```

---

## Running Tests

### Quick Test (No Cluster Required)

```bash
# Run all unit tests
./tests/test-registry-config.sh
```

### Full Test Suite

```bash
# Run all tests (unit + integration if cluster available)
./tests/run-all-tests.sh
```

### CI/CD Tests

Tests automatically run on:
- Every push to `main` or `develop`
- Every pull request
- Manual workflow dispatch

```bash
# Simulate CI locally with act (requires Docker)
act push
```

---

## Bug Case Study: Registry Configuration

### The Bug

**Issue**: `failed to open registry config file at /tmp/registries.yaml: no such file or directory`

**Affected Scenario**: Using `--private-registry` WITHOUT `--registry-secret`

### Root Cause Analysis

The bug was in `install.sh:728-731` where the copy of `registries.yaml` to `/tmp` was inside the `REGISTRY_SECRET` conditional:

```bash
# BUGGY CODE (before fix)
if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
    # Setup credentials...
    # Pre-pull images...
    
    # Copy registries.yaml to /tmp  ← ONLY RUNS WITH SECRET!
    cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml
fi

# Later...
if [[ -n "$PRIVATE_REGISTRY" ]]; then
    # k3d always uses /tmp/registries.yaml  ← EXPECTS FILE!
    K3D_ARGS="$K3D_ARGS --registry-config /tmp/registries.yaml"
fi
```

**The problem**: File copy happened only with secret, but k3d always expected the file.

### The Fix

Moved the file copy operation outside the credential conditional:

```bash
# FIXED CODE
if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
    # Setup credentials...
    # Pre-pull images...
fi

# Copy registries.yaml ALWAYS when using private registry
if [[ -n "$PRIVATE_REGISTRY" ]]; then
    cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml
    chmod 644 /tmp/registries.yaml
fi

# Later...
if [[ -n "$PRIVATE_REGISTRY" ]]; then
    K3D_ARGS="$K3D_ARGS --registry-config /tmp/registries.yaml"
fi
```

### Why It Reached Production

**Testing Gap**: Only tested with authentication (`--registry-secret`), which worked fine.

**Test Matrix Gaps**:
- ✅ Tested: Private registry WITH auth
- ❌ Not tested: Private registry WITHOUT auth
- ❌ Not tested: Insecure/open registries

### Prevention Strategy

Created comprehensive test coverage:

1. **Test Matrix** (all combinations):
   ```
   - No private registry
   - Private registry without auth
   - Private registry with auth
   - Private registry with path prefix
   - Private registry with insecure flag
   ```

2. **Specific Regression Test**:
   ```bash
   test_file_copy_without_secret() {
       # Ensures the bug stays fixed
       # Validates file copy happens without secret
   }
   ```

3. **CI/CD Validation**:
   - All test scenarios run automatically
   - Pull requests blocked if tests fail
   - Dry-run validation of all configurations

### Verification

The bug fix is verified by:

```bash
# Test 1: Generate manifest without secret
./install.sh --name test --private-registry docker.local --dry-run > /tmp/test.yaml

# Verify file copy exists
grep -q "cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml" /tmp/test.yaml
echo "✓ File copy present"

# Verify it happens before k3d create
COPY_LINE=$(grep -n "cp /etc/rancher/k3s/registries.yaml" /tmp/test.yaml | cut -d: -f1)
CREATE_LINE=$(grep -n "k3d cluster create" /tmp/test.yaml | cut -d: -f1)
if [[ $COPY_LINE -lt $CREATE_LINE ]]; then
    echo "✓ File copy happens before k3d create"
fi

# Verify k3d uses the file
grep -q -- "--registry-config /tmp/registries.yaml" /tmp/test.yaml
echo "✓ k3d configured to use /tmp/registries.yaml"
```

---

## CI/CD Integration

### GitHub Actions Workflow

Located at `.github/workflows/test.yml`

**Jobs**:
1. **Lint**: Shellcheck validation
2. **Unit Tests**: Fast validation without cluster
3. **Dry-Run Tests**: Manifest generation and validation
4. **Integration Tests**: Full deployment in Kind cluster

**Matrix Testing**:
```yaml
strategy:
  matrix:
    scenario:
      - name: no-registry
      - name: registry-no-auth
      - name: registry-with-auth
      - name: registry-path-prefix
      - name: insecure-registry
```

### Pre-commit Hooks (Optional)

Create `.git/hooks/pre-commit`:
```bash
#!/bin/bash
echo "Running tests before commit..."
./tests/run-all-tests.sh || {
    echo "Tests failed! Commit aborted."
    exit 1
}
```

---

## Adding New Tests

### 1. Create Test File

```bash
# Create new test suite
cat > tests/test-my-feature.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Test implementation...
EOF

chmod +x tests/test-my-feature.sh
```

### 2. Add to Test Runner

Edit `tests/run-all-tests.sh`:
```bash
run_test_suite "My Feature" "$SCRIPT_DIR/test-my-feature.sh"
```

### 3. Add to CI/CD

Edit `.github/workflows/test.yml`:
```yaml
- name: Run my feature tests
  run: ./tests/test-my-feature.sh
```

### Test Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# Setup
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

test_pass() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo "[PASS] $1"
}

test_fail() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "[FAIL] $1: $2"
}

# Test cases
test_something() {
    # Test logic...
    if [[ condition ]]; then
        test_pass "Test name"
    else
        test_fail "Test name" "reason"
    fi
}

# Run tests
test_something

# Summary
echo ""
echo "Tests: $TOTAL_TESTS, Passed: $PASSED_TESTS, Failed: $FAILED_TESTS"
exit $FAILED_TESTS
```

---

## Test Coverage Goals

Current coverage (v1.0):
- ✅ Registry configuration: 6 test cases
- ⚠️ Installation scenarios: TODO
- ⚠️ Management commands: TODO
- ⚠️ Access methods (NodePort/LB/Ingress): TODO

Target coverage (v2.0):
- All installation options
- All management commands
- Multi-instance scenarios
- Upgrade paths
- Error handling

---

## Best Practices

### DO:
- ✅ Test both happy paths AND edge cases
- ✅ Test feature combinations (matrix testing)
- ✅ Add regression tests for every bug fix
- ✅ Keep tests fast and reliable
- ✅ Clean up test resources

### DON'T:
- ❌ Only test the "main" use case
- ❌ Skip edge cases or error scenarios
- ❌ Assume features work without testing
- ❌ Leave test resources running
- ❌ Write flaky tests

### When to Add Tests

**Always add tests for**:
- New features
- Bug fixes (regression tests)
- Edge cases you discover
- User-reported issues
- Complex conditional logic

### Test Naming Convention

```
test_<feature>_<scenario>_<expected_outcome>

Examples:
- test_registry_without_auth_succeeds
- test_configmap_generation_with_path_prefix
- test_invalid_nodeport_fails_validation
```

---

## Troubleshooting Tests

### Tests Fail Locally But Pass in CI

Check:
- Kubernetes cluster version
- kubectl version
- Permissions (privileged pods)
- Storage provisioner availability

### Integration Tests Timeout

- Increase `--wait-timeout` value
- Check cluster resources
- Review pod logs: `kubectl logs -n k3s-test -l app=k3s`

### Cleanup Issues

```bash
# Manual cleanup
./manage.sh delete-all
kubectl get namespaces | grep k3s | cut -d' ' -f1 | xargs kubectl delete namespace
```

---

## Contributing

When submitting a PR:

1. ✅ Add tests for new features
2. ✅ Ensure all tests pass locally
3. ✅ Update this document if adding new test types
4. ✅ Add test cases to verify bug fixes

---

## Questions?

- Test failures: Check logs in `reports/` directory
- CI/CD issues: Check GitHub Actions tab
- New test ideas: Open an issue

**Remember**: The bug we fixed could have been caught with proper testing. Let's prevent the next one! 🛡️

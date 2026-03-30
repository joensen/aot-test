#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PETCLINIC_DIR="$SCRIPT_DIR/petclinic"
IMAGE_NAME="petclinic-aot"
CONTAINER_NAME="petclinic-benchmark"

echo "============================================================"
echo "  Podman AOT Cache Benchmark"
echo "============================================================"
echo ""

# Step 1: Ensure PetClinic is cloned
if [ ! -d "$PETCLINIC_DIR" ]; then
    echo "[1/4] Cloning Spring PetClinic..."
    git clone https://github.com/spring-projects/spring-petclinic.git petclinic
else
    echo "[1/4] PetClinic already cloned."
fi
echo ""

# Step 2: Copy the Dockerfile into the project and build the image
echo "[2/4] Building container image (this may take several minutes on first run)..."
cp "$SCRIPT_DIR/Dockerfile" "$PETCLINIC_DIR/Dockerfile"
podman build -t "$IMAGE_NAME" "$PETCLINIC_DIR"
echo "       Image built: $IMAGE_NAME"
echo ""

# Helper: wait for startup in container logs, return startup time
wait_and_extract_time() {
    local logfile=$1
    local timeout=120
    local elapsed=0
    while ! podman logs "$CONTAINER_NAME" 2>&1 | grep -q "Started PetClinicApplication in" 2>/dev/null; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$((timeout * 2))" ]; then
            echo "ERROR: Application did not start within ${timeout}s"
            podman logs "$CONTAINER_NAME" > "$logfile" 2>&1
            podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
            return 1
        fi
    done
    podman logs "$CONTAINER_NAME" > "$logfile" 2>&1
    grep -o "Started PetClinicApplication in [0-9.]*" "$logfile" | grep -o "[0-9.]*$"
}

# Step 3: Run with AOT Cache + Spring AOT (the image default)
echo "[3/4] Running with Spring AOT + JVM AOT Cache..."
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
podman run -d --name "$CONTAINER_NAME" -p 8080:8080 "$IMAGE_NAME"
AOT_TIME=$(wait_and_extract_time "$SCRIPT_DIR/docker-aot.log")
echo "       Started in ${AOT_TIME}s"
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
sleep 3
echo ""

# Step 4: Run baseline (override entrypoint to disable both optimizations)
echo "[4/4] Running BASELINE (no optimizations)..."
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
podman run -d --name "$CONTAINER_NAME" -p 8080:8080 \
    --entrypoint sh "$IMAGE_NAME" \
    -c "java -jar /app/*.jar"
BASELINE_TIME=$(wait_and_extract_time "$SCRIPT_DIR/docker-baseline.log")
echo "       Started in ${BASELINE_TIME}s"
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
echo ""

# Results
echo "============================================================"
echo "  Podman Benchmark Results"
echo "============================================================"
echo ""
printf "  %-40s %10s\n" "Scenario" "Startup"
printf "  %-40s %10s\n" "----------------------------------------" "----------"
printf "  %-40s %9ss\n" "Baseline (no optimizations)" "$BASELINE_TIME"
printf "  %-40s %9ss\n" "Spring AOT + JVM AOT Cache" "$AOT_TIME"
echo ""

if command -v bc &>/dev/null; then
    SPEEDUP=$(echo "scale=1; $BASELINE_TIME / $AOT_TIME" | bc)
    printf "  %-40s %9sx\n" "Speedup" "$SPEEDUP"
    echo ""
fi

echo "============================================================"

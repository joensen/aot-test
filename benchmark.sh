#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export JAVA_HOME="$SCRIPT_DIR/jdk-25"
export PATH="$JAVA_HOME/bin:$PATH"

EXTRACTED_DIR="$SCRIPT_DIR/extracted"
EXTRACTED_AOT_DIR="$SCRIPT_DIR/extracted-aot"
APP_JAR=$(ls "$EXTRACTED_DIR"/spring-petclinic-*.jar 2>/dev/null | head -1)
APP_AOT_JAR=$(ls "$EXTRACTED_AOT_DIR"/spring-petclinic-*.jar 2>/dev/null | head -1)

if [ -z "$APP_JAR" ]; then
    echo "ERROR: No standard JAR found in extracted/. Run ./setup.sh first."
    exit 1
fi
if [ -z "$APP_AOT_JAR" ]; then
    echo "ERROR: No AOT JAR found in extracted-aot/. Run ./setup.sh first."
    exit 1
fi

echo "============================================================"
echo "  Java 25 AOT Cache + Spring AOT Benchmark"
echo "============================================================"
echo "  JDK: $(java -version 2>&1 | head -1)"
echo "  Standard JAR:   $APP_JAR"
echo "  Spring AOT JAR: $APP_AOT_JAR"
echo "============================================================"
echo ""

# Helper: wait for Spring Boot startup and extract time
wait_for_startup() {
    local logfile=$1
    local timeout=120
    local elapsed=0
    while ! grep -q "Started PetClinicApplication in" "$logfile" 2>/dev/null; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$((timeout * 2))" ]; then
            echo "ERROR: Application did not start within ${timeout}s"
            return 1
        fi
    done
    grep -o "Started PetClinicApplication in [0-9.]*" "$logfile" | grep -o "[0-9.]*$"
}

# Helper: stop application
stop_app() {
    local pid=$1
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        wait "$pid" 2>/dev/null || true
    fi
}

# Helper: wait for port to free up
wait_for_port() {
    sleep 3
}

# ============================================================
# Run 1: Baseline (no optimizations)
# ============================================================
echo "[1/6] Running BASELINE (no optimizations)..."
rm -f baseline.log
java -jar "$APP_JAR" > baseline.log 2>&1 &
PID=$!

BASELINE_TIME=$(wait_for_startup baseline.log)
echo "       Started in ${BASELINE_TIME}s"
stop_app $PID
echo "       Stopped."
echo ""
wait_for_port

# ============================================================
# Run 2: JVM AOT Cache training (standard JAR)
# ============================================================
echo "[2/6] Training JVM AOT cache (standard JAR)..."
rm -f app.aot training.log
java -XX:AOTCacheOutput="$SCRIPT_DIR/app.aot" \
     -Dspring.context.exit=onRefresh \
     -jar "$APP_JAR" > training.log 2>&1 || true

if [ ! -f "$SCRIPT_DIR/app.aot" ]; then
    echo "ERROR: AOT cache file was not created! Check training.log"
    exit 1
fi
echo "       Cache created: $(du -h "$SCRIPT_DIR/app.aot" | cut -f1)"
echo ""
wait_for_port

# ============================================================
# Run 3: JVM AOT Cache only
# ============================================================
echo "[3/6] Running with JVM AOT CACHE only..."
rm -f aot-cache.log
java -XX:AOTCache="$SCRIPT_DIR/app.aot" \
     -jar "$APP_JAR" > aot-cache.log 2>&1 &
PID=$!

AOT_CACHE_TIME=$(wait_for_startup aot-cache.log)
echo "       Started in ${AOT_CACHE_TIME}s"
stop_app $PID
echo "       Stopped."
echo ""
wait_for_port

# ============================================================
# Run 4: Spring AOT only (no JVM AOT cache)
# ============================================================
echo "[4/6] Running with SPRING AOT only..."
rm -f spring-aot.log
java -Dspring.aot.enabled=true \
     -jar "$APP_AOT_JAR" > spring-aot.log 2>&1 &
PID=$!

SPRING_AOT_TIME=$(wait_for_startup spring-aot.log)
echo "       Started in ${SPRING_AOT_TIME}s"
stop_app $PID
echo "       Stopped."
echo ""
wait_for_port

# ============================================================
# Run 5: JVM AOT Cache training (Spring AOT JAR)
# ============================================================
echo "[5/6] Training JVM AOT cache (Spring AOT JAR)..."
rm -f app-aot.aot training-aot.log
java -XX:AOTCacheOutput="$SCRIPT_DIR/app-aot.aot" \
     -Dspring.aot.enabled=true \
     -Dspring.context.exit=onRefresh \
     -jar "$APP_AOT_JAR" > training-aot.log 2>&1 || true

if [ ! -f "$SCRIPT_DIR/app-aot.aot" ]; then
    echo "ERROR: AOT cache file was not created! Check training-aot.log"
    exit 1
fi
echo "       Cache created: $(du -h "$SCRIPT_DIR/app-aot.aot" | cut -f1)"
echo ""
wait_for_port

# ============================================================
# Run 6: Spring AOT + JVM AOT Cache (combined)
# ============================================================
echo "[6/6] Running with SPRING AOT + JVM AOT CACHE (combined)..."
rm -f combined.log
java -XX:AOTCache="$SCRIPT_DIR/app-aot.aot" \
     -Dspring.aot.enabled=true \
     -jar "$APP_AOT_JAR" > combined.log 2>&1 &
PID=$!

COMBINED_TIME=$(wait_for_startup combined.log)
echo "       Started in ${COMBINED_TIME}s"
stop_app $PID
echo "       Stopped."
echo ""

# ============================================================
# Results
# ============================================================
echo "============================================================"
echo "  Results"
echo "============================================================"
echo ""
printf "  %-35s %10s\n" "Scenario" "Startup"
printf "  %-35s %10s\n" "-----------------------------------" "----------"
printf "  %-35s %9ss\n" "1. Baseline (no optimizations)" "$BASELINE_TIME"
printf "  %-35s %9ss\n" "2. JVM AOT Cache only" "$AOT_CACHE_TIME"
printf "  %-35s %9ss\n" "3. Spring AOT only" "$SPRING_AOT_TIME"
printf "  %-35s %9ss\n" "4. Spring AOT + JVM AOT Cache" "$COMBINED_TIME"
echo ""

if command -v bc &>/dev/null; then
    echo "  Speedups vs baseline:"
    AOT_CACHE_SPEEDUP=$(echo "scale=1; $BASELINE_TIME / $AOT_CACHE_TIME" | bc)
    SPRING_AOT_SPEEDUP=$(echo "scale=1; $BASELINE_TIME / $SPRING_AOT_TIME" | bc)
    COMBINED_SPEEDUP=$(echo "scale=1; $BASELINE_TIME / $COMBINED_TIME" | bc)
    printf "  %-35s %9sx\n" "2. JVM AOT Cache only" "$AOT_CACHE_SPEEDUP"
    printf "  %-35s %9sx\n" "3. Spring AOT only" "$SPRING_AOT_SPEEDUP"
    printf "  %-35s %9sx\n" "4. Spring AOT + JVM AOT Cache" "$COMBINED_SPEEDUP"
    echo ""
fi

echo "============================================================"

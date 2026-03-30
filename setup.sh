#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

JDK_DIR="$SCRIPT_DIR/jdk-25"
PETCLINIC_DIR="$SCRIPT_DIR/petclinic"

echo "========================================="
echo "  Java 25 AOT Cache Test - Setup"
echo "========================================="

# Step 1: Download and extract JDK 25
if [ -d "$JDK_DIR" ] && [ -f "$JDK_DIR/bin/java" -o -f "$JDK_DIR/bin/java.exe" ]; then
    echo "[1/6] JDK 25 already exists, skipping download."
else
    echo "[1/6] Downloading JDK 25 (Temurin, Windows x64)..."
    curl -L -o temurin-25.zip \
        "https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse"
    echo "       Extracting..."
    unzip -q temurin-25.zip
    rm temurin-25.zip
    # Rename the extracted directory (e.g., jdk-25.0.2+10) to jdk-25
    extracted=$(ls -d jdk-25* 2>/dev/null | head -1)
    if [ -n "$extracted" ] && [ "$extracted" != "jdk-25" ]; then
        mv "$extracted" jdk-25
    fi
fi

export JAVA_HOME="$JDK_DIR"
export PATH="$JAVA_HOME/bin:$PATH"

echo "       Verifying JDK..."
java -version
echo ""

# Step 2: Clone PetClinic
if [ -d "$PETCLINIC_DIR" ]; then
    echo "[2/6] PetClinic already cloned, skipping."
else
    echo "[2/6] Cloning Spring PetClinic..."
    git clone https://github.com/spring-projects/spring-petclinic.git petclinic
fi
echo ""

cd "$PETCLINIC_DIR"

# Step 3: Build the standard JAR
echo "[3/6] Building PetClinic (standard)..."
./mvnw package -DskipTests
echo "       Build complete."
echo ""

# Step 4: Extract the standard JAR
JAR_FILE=$(ls target/spring-petclinic-*.jar 2>/dev/null | head -1)
if [ -z "$JAR_FILE" ]; then
    echo "ERROR: Could not find built JAR in target/"
    exit 1
fi
echo "[4/6] Extracting standard JAR..."
rm -rf "$SCRIPT_DIR/extracted"
java -Djarmode=tools -jar "$JAR_FILE" extract --destination "$SCRIPT_DIR/extracted"
echo "       Extracted to extracted/"
echo ""

# Step 5: Build with Spring AOT processing (-Pnative triggers process-aot goal)
echo "[5/6] Building PetClinic with Spring AOT processing..."
./mvnw package -DskipTests -Pnative
echo "       Spring AOT build complete."
echo ""

# Step 6: Extract the AOT-processed JAR
AOT_JAR_FILE=$(ls target/spring-petclinic-*.jar 2>/dev/null | head -1)
echo "[6/6] Extracting Spring AOT-processed JAR..."
rm -rf "$SCRIPT_DIR/extracted-aot"
java -Djarmode=tools -jar "$AOT_JAR_FILE" extract --destination "$SCRIPT_DIR/extracted-aot"
echo "       Extracted to extracted-aot/"
echo ""

echo "========================================="
echo "  Setup complete!"
echo "  Run ./benchmark.sh to compare startup times"
echo "========================================="

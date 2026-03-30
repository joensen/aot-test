# ============================================================
# Stage 1: Build the Spring AOT-processed JAR
# ============================================================
FROM eclipse-temurin:25-jdk AS build

WORKDIR /build
COPY . .

# -Pnative triggers the process-aot goal (Spring AOT code generation)
# We only need the JAR, not a native image
RUN ./mvnw package -DskipTests -Pnative

# ============================================================
# Stage 2: Extract JAR and create AOT cache (training run)
# ============================================================
FROM eclipse-temurin:25-jdk AS training

WORKDIR /app

# Copy the built JAR from the build stage
COPY --from=build /build/target/*.jar application.jar

# Extract the uber JAR (required for AOT cache - no nested JARs allowed)
RUN java -Djarmode=tools -jar application.jar extract --destination extracted

# Training run: creates the AOT cache file
# -Dspring.context.exit=onRefresh exits after context is fully initialized
# -Dspring.aot.enabled=true activates Spring AOT-generated code during training
RUN java \
    -XX:AOTCacheOutput=/app/app.aot \
    -Dspring.aot.enabled=true \
    -Dspring.context.exit=onRefresh \
    -jar extracted/*.jar

# ============================================================
# Stage 3: Production image
# ============================================================
FROM eclipse-temurin:25-jdk AS production

WORKDIR /app

# Copy extracted JAR layout and AOT cache from training stage
COPY --from=training /app/extracted/ ./
COPY --from=training /app/app.aot ./app.aot

EXPOSE 8080

# Run with both optimizations enabled
ENTRYPOINT ["sh", "-c", \
    "java -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/*.jar"]

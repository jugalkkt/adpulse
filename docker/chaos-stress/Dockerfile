# CPU stressor for the cpu-hog chaos scenario (a deliberate noisy neighbour).
# Runs as non-root; the chaos tool labels the container com.adpulse.role=chaos
# and always passes --timeout so it can never run longer than 3 minutes.
ARG BASE_IMAGE=adpulse-base:dev
FROM ${BASE_IMAGE}

ARG STRESS_NG_VERSION=0.17.06-1build1
LABEL com.adpulse.project="adpulse" com.adpulse.role="chaos" org.opencontainers.image.title="adpulse-chaos-stress"

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends "stress-ng=${STRESS_NG_VERSION}" \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/*
USER adpulse
ENTRYPOINT ["stress-ng"]
CMD ["--cpu", "1", "--timeout", "60s"]

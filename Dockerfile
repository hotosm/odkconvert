# Copyright (c) 2022, 2023 Humanitarian OpenStreetMap Team
# This file is part of osm-fieldwork.
#
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with osm-fieldwork.  If not, see <https:#www.gnu.org/licenses/>.
#
ARG PYTHON_IMG_TAG=3.10

FROM docker.io/python:${PYTHON_IMG_TAG}-slim-bookworm as base
ARG PYTHON_IMG_TAG
ARG PKG_VERSION
ARG MAINTAINER=admin@hotosm.org
LABEL org.hotosm.osm-fieldwork.python-img-tag="${PYTHON_IMG_TAG}" \
      org.hotosm.osm-fieldwork.maintainer="${MAINTAINER}" \
      org.hotosm.osm-fieldwork.version="${PKG_VERSION}"

RUN set -ex \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install \
    -y --no-install-recommends "locales" "ca-certificates" \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates
# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8



FROM base as build
ARG PKG_VERSION
WORKDIR /opt/python
RUN set -ex \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install \
    -y --no-install-recommends \
        "build-essential" \
        "gcc" \
        "libpcre3-dev" \
        "libspatialindex-dev" \
        "libproj-dev" \
        "libgeos-dev" \
        "libgdal-dev" \
    && rm -rf /var/lib/apt/lists/*
COPY pyproject.toml pdm.lock /opt/python/
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir pdm==2.6.1
RUN pdm export --prod > requirements.txt \
    && pdm export -G debug -G test --no-default \
    --without-hashes > requirements-test.txt
RUN pip install --user --no-warn-script-location \
    --no-cache-dir -r ./requirements.txt
COPY . .
RUN pdm build
RUN pip install --user --no-warn-script-location \
    --no-cache-dir "dist/osm_fieldwork-$PKG_VERSION-py3-none-any.whl"



FROM base as runtime
ARG PYTHON_IMG_TAG
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    PATH="/home/appuser/.local/bin:$PATH" \
    PYTHON_LIB="/home/appuser/.local/lib/python$PYTHON_IMG_TAG/site-packages" \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
RUN set -ex \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install \
    -y --no-install-recommends \
        "nano" \
        "curl" \
        "gosu" \
        "libpcre3" \
        "libglib2.0-0" \
        "libspatialindex-c6" \
        "libproj25" \
        "libgeos-c1v5" \
        "libgdal32" \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build \
    /root/.local \
    /home/appuser/.local
WORKDIR /home/appuser
# Add non-root user, permissions
RUN useradd -r -u 900 -m -c "hotosm account" -d /home/appuser -s /bin/false appuser \
    && chown -R appuser:appuser /home/appuser
# Change to non-root user
USER appuser
CMD ["python", "$@"]



FROM runtime as ci
COPY --from=build --chown=appuser \
    /opt/python/requirements-test.txt /opt/python/
RUN pip install --user --no-warn-script-location \
    --no-cache-dir -r /opt/python/requirements-test.txt
COPY --chown=appuser tests/ /home/appuser/tests/
# Pre-compile packages to .pyc (init speed gains)
RUN python -c "import compileall; compileall.compile_path(maxlevels=10, quiet=1)"
# Override entrypoint, as not possible in Github action
ENTRYPOINT [""]
CMD [""]



FROM runtime as prod
# Pre-compile packages to .pyc (init speed gains)
RUN python -c "import compileall; compileall.compile_path(maxlevels=10, quiet=1)"
# Note: 4 uvicorn workers as running with docker, change to 1 worker for Kubernetes
CMD ["python", "$@"]

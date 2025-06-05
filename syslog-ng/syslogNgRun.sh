#!/bin/bash
podman stop d0clcsec1_syslog-ng1
podman rm d0clcsec1_syslog-ng1
podman run -d \
  --name d0clcsec1_syslog-ng1 \
  --net host \
  -v /vzpelk/syslog-ng/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:Z \
  -v /vzpelk/syslog-ng/conf.d:/etc/syslog-ng/conf.d:Z \
  -v /vzpelk/syslog-ng/patterndb_proxy.xml:/etc/syslog-ng/patterndb_proxy.xml:Z \
  -v /vzpelk/syslog-ng/certs:/etc/syslog-ng/certs:Z \
  -v /datastore/containers/syslog-ng1/ingest:/datastore/containers/syslog-ng1/ingest:Z \
  registry4elk.azurecr.io/custom-syslog-ng:with-grok /usr/local/sbin/syslog-ng -F \
  -e -f /etc/syslog-ng/syslog-ng.conf
#-v -e -d -f /etc/syslog-ng/syslog-ng.conf

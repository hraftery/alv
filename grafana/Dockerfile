FROM grafana/grafana:13.1.0

# Pre-install plugins at image build time rather than via GF_INSTALL_PLUGINS.
# GF_INSTALL_PLUGINS delegates to the background installer at runtime, which
# also triggers unsolicited installs of unrelated plugins (e.g. elasticsearch),
# producing noisy failure logs when the registry is unreachable.
RUN grafana cli plugins install victoriametrics-logs-datasource

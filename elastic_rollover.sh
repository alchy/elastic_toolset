#!/bin/bash

# --- Konfigurace skriptu ---
# Nastavení debug režimu (zapne set -x a případně detailní curl trace)
# Pro vypnutí debugu nastav DEBUG_MODE="false" nebo jen zakomentuj.
DEBUG_MODE="false"

# Cesta k souboru s proměnnými prostředí (credentials)
ENV_FILE="/vzpelk/site/.env"

# Elasticsearch host
ES_HOST="https://clcsec.dc.vzp.cz:9200"

# Cesta k CA certifikátu pro curl
CA_CERT="/etc/kibana/kibana-certs/ca.pem"

# Logovací soubor (hlavní, stručnější log)
LOG_FILE="/var/log/elastic_rollover.log"

# Debug logovací soubor (detailní výstup set -x, ale bez opakovaného curl -v)
DEBUG_LOG_FILE="/var/log/elastic_rollover_debug.log"

# Soubor pro extra detailní trace curl (pouze při chybě)
CURL_TRACE_FILE="/tmp/curl_trace_rollover_$(date +%Y%m%d%H%M%S).log"

# Regex pro filtrování aliasů, které chceme rolovat
ROLLOVER_ALIAS_REGEX="syslog-(proxy|apm|afm|unix|net|gtm|ips)|auditbeat|winlogbeat"

# --- Inicializace a nastavení ---

# Přesměrování standardního výstupu a chybového výstupu do hlavního log souboru
exec &> >(tee -a "${LOG_FILE}")

echo "=== Spuštění Elastic Rollover Skriptu: $(date) ==="

# Kontrola existence .env souboru a načtení creds
if [ -f "${ENV_FILE}" ]; then
  source "${ENV_FILE}"
else
  echo "Chyba: Soubor .env nenalezen na ${ENV_FILE}. Ukončuji skript."
  exit 1
fi

# Kontrola, zda jsou ELASTIC_USERNAME a ELASTIC_PASSWORD definovány
if [ -z "${ELASTIC_USERNAME}" ] || [ -z "${ELASTIC_PASSWORD}" ]; then
  echo "Chyba: ELASTIC_USERNAME nebo ELASTIC_PASSWORD nejsou nastaveny v ${ENV_FILE}. Ukončuji skript."
  exit 1
fi

# Curl možnosti s autentizací a certifikátem (vždy tichý, pokud není explicitně trace)
CURL_COMMON_OPTS="-u ${ELASTIC_USERNAME}:${ELASTIC_PASSWORD} --cacert ${CA_CERT} -s"

# Nastavení debug módu
if [ "${DEBUG_MODE}" == "true" ]; then
  # Zapnutí set -x a jeho přesměrování do debug logu
  # Všechny příkazy s + budou v DEBUG_LOG_FILE
  exec 3>&1 4>&2 # Záloha stdout a stderr
  trap 'exec 2>&4 1>&3' EXIT # Obnovení stdout a stderr při exitu
  exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Přesměrování stdout a stderr do debug logu
  set -x # Zobrazuje prováděné příkazy
  exec 1>&3 2>&4 # Dočasné obnovení stdout a stderr pro následující echo a print
  echo "--- DEBUG MÓD ZAPNUT: Podrobný průběh skriptu je v ${DEBUG_LOG_FILE} ---" >&2 # Zpráva pro hlavní log/konzoli
  exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu
fi

# Dočasný soubor pro uložení JSON výstupu z curl
TEMP_JSON_DATA=$(mktemp)

# Funkce pro úklid dočasných souborů při exitu skriptu
trap "rm -f ${TEMP_JSON_DATA} ${CURL_TRACE_FILE}" EXIT

# Funkce pro kontrolu chyby curl příkazu
# Nyní v případě chyby vypíše dočasný trace soubor a smaže ho
check_curl_error() {
  local command_desc="$1"
  local curl_cmd="$2" # Přenášíme původní curl příkaz
  if [ $? -ne 0 ]; then
    echo "Chyba: Selhalo provedení curl příkazu pro ${command_desc}. Více detailů v logu." >&2
    echo "  -- Pokus o detailní curl trace pro diagnostiku chyby --" >&2
    # Spustíme curl znovu s verbose a trace do samostatného souboru
    # Výstup trace file půjde přímo do hlavního logu (stdin/stderr) pro okamžitou viditelnost
    echo "Detailní trace je zde: ${CURL_TRACE_FILE}" >&2

    # Dočasně vypneme set -x pro čistší výstup curl trace
    if [ "${DEBUG_MODE}" == "true" ]; then
      set +x
      exec 1>&3 2>&4 # Zpět do hlavního logu pro trace
    fi

    # Provedeme curl s trace-ascii a uložení do CURL_TRACE_FILE
    # Zde nepoužijeme proměnnou, ale přímo přesměrování pro čistotu
    echo "Running: ${curl_cmd}" >&2
    eval "${curl_cmd}" --trace-ascii "${CURL_TRACE_FILE}" >/dev/null 2>&1 # Přesměrujeme stdout/stderr, aby nezahlcovaly.

    # Zobrazíme obsah trace souboru v hlavním logu
    if [ -f "${CURL_TRACE_FILE}" ]; then
      echo "--- OBSAH CURL TRACE FILU (${CURL_TRACE_FILE}) ---" >&2
      cat "${CURL_TRACE_FILE}" >&2
      echo "--- KONEC CURL TRACE FILU ---" >&2
    fi

    if [ "${DEBUG_MODE}" == "true" ]; then
      exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu
      set -x
    fi

    exit 1 # Kritická chyba, ukončuje skript
  fi
}

# --- Získání a filtrování aliasů ---
echo "Získávám seznam všech aliasů z Elasticsearch..."

# Použijeme tichý curl, výstup uložíme do TEMP_JSON_DATA
CURL_ALIASES_CMD="curl ${CURL_COMMON_OPTS} -X GET \"${ES_HOST}/_cat/aliases?format=json\""
ALIAS_DATA=$(eval "${CURL_ALIASES_CMD}")
echo "${ALIAS_DATA}" > "${TEMP_JSON_DATA}"
check_curl_error "načtení aliasů" "${CURL_ALIASES_CMD}"

# Uložení raw JSON dat pro debugování (v debug módu jen ukázka, zbytek v temp souboru)
if [ "${DEBUG_MODE}" == "true" ]; then
  exec 1>&3 2>&4 # Dočasné obnovení pro echo do hlavního logu
  echo "Raw _cat/aliases odpověď (celý JSON je v ${TEMP_JSON_DATA}, ukázka prvních 10 řádků):"
  head -n 10 "${TEMP_JSON_DATA}" # Zobrazit jen prvních 10 řádků
  echo "..."
  exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu
fi

echo "Filtruji aliasy pro rollover (regex: ${ROLLOVER_ALIAS_REGEX})."

# Filtr pro indexy, které splňují následující podmínky:
INDICES=$(jq -r \
  ".[] | select(
    (.alias | type == \"string\") and
    (.is_write_index | type == \"string\") and
    (.is_write_index == \"true\") and
    (.alias | startswith(\".\") | not) and  # ZDE JE OPRAVA: startofswith -> startswith
    (.alias | test(\"${ROLLOVER_ALIAS_REGEX}\"))
  ) | .index" "${TEMP_JSON_DATA}")

JQ_EXIT_CODE=$?
if [ ${JQ_EXIT_CODE} -ne 0 ]; then
  exec 1>&3 2>&4 # Zpět do hlavního logu
  echo "Chyba: jq selhalo při parsování aliasů (exit code: ${JQ_EXIT_CODE}). Zkontrolujte formát JSON dat v ${TEMP_JSON_DATA}."
  exit 1
fi

exec 1>&3 2>&4 # Zpět do hlavního logu pro tisk výsledků
echo "Nalezené indexy pro rollover:"
if [ -z "${INDICES}" ]; then
  echo "Žádné indexy pro rollover nebyly nalezeny podle regexu: ${ROLLOVER_ALIAS_REGEX}."
  echo "Ukončuji skript."
  exit 0
else
  echo "${INDICES}"
fi
exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu, pokud je DEBUG_MODE


# --- Provedení rolloveru ---
for INDEX in ${INDICES}; do
  # Získání aliasu pro aktuální index (který je zároveň write indexem)
  ALIAS=$(jq -r \
    ".[] | select(
      .index == \"${INDEX}\" and
      (.alias | type == \"string\") and
      (.is_write_index | type == \"string\") and
      (.is_write_index == \"true\")
    ) | .alias" "${TEMP_JSON_DATA}")

  if [ -z "${ALIAS}" ]; then
    exec 1>&3 2>&4 # Zpět do hlavního logu
    echo "Varování: Platný write alias pro index ${INDEX} nenalezen. Přeskakuji rollover pro tento index."
    continue
  fi

  exec 1>&3 2>&4 # Zpět do hlavního logu
  echo "--- Provádím rollover pro index: ${INDEX} (alias: ${ALIAS}) ---"
  exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu, pokud je DEBUG_MODE

  # Provedení rolloveru (tichý curl, trace jen při chybě)
  CURL_ROLLOVER_CMD="curl ${CURL_COMMON_OPTS} -X POST \"${ES_HOST}/${ALIAS}/_rollover\" -H 'Content-Type: application/json'"
  ROLLOVER_RESPONSE=$(eval "${CURL_ROLLOVER_CMD}")
  check_curl_error "rollover pro alias ${ALIAS}" "${CURL_ROLLOVER_CMD}"

  exec 1>&3 2>&4 # Zpět do hlavního logu
  echo "Odpověď z rollover API pro alias ${ALIAS}:"
  echo "${ROLLOVER_RESPONSE}"

  # Kontrola úspěšnosti rolloveru
  SUCCESS=$(echo "${ROLLOVER_RESPONSE}" | jq -r '.acknowledged // false')
  OLD_INDEX=$(echo "${ROLLOVER_RESPONSE}" | jq -r '.old_index // "Neznámý"')
  NEW_INDEX=$(echo "${ROLLOVER_RESPONSE}" | jq -r '.new_index // "Neznámý"')

  if [ "${SUCCESS}" == "true" ]; then
    echo "  Rollover úspěšný pro alias ${ALIAS}."
    echo "  Starý index: ${OLD_INDEX}"
    echo "  Nový aktivní write index: ${NEW_INDEX}"
  else
    ERROR_MESSAGE=$(echo "${ROLLOVER_RESPONSE}" | jq -r '.error.reason // "Neznámá chyba v JSON odpovědi."')
    echo "  Chyba: Rollover pro alias ${ALIAS} selhal: ${ERROR_MESSAGE}"
    echo "  Celá odpověď: ${ROLLOVER_RESPONSE}" # Zobrazit celou odpověď pro detailnější debug
  fi
  exec 1> "${DEBUG_LOG_FILE}" 2>&1 # Zpět do debug logu, pokud je DEBUG_MODE
done

exec 1>&3 2>&4 # Zpět do hlavního logu
echo "=== Proces rolloveru dokončen. ==="
echo "Veškerý běžný výstup byl zaznamenán do souboru: ${LOG_FILE}"
if [ "${DEBUG_MODE}" == "true" ]; then
  echo "Detailní debug výstup (průběh skriptu) je k dispozici v souboru: ${DEBUG_LOG_FILE}"
  echo "Případné detailní curl trace soubory budou v /tmp/ a budou mít název 'curl_trace_rollover_*.log'."
fi

exit 0

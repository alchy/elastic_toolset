#!/bin/bash

# --- Konfigurace skriptu ---
# Cesta k souboru s proměnnými prostředí (credentials)
ENV_FILE="/vzpelk/site/.env"

# Elasticsearch host
ES_HOST="https://clcsec.dc.vzp.cz:9200"

# Cesta k CA certifikátu pro curl
CA_CERT="/etc/kibana/kibana-certs/ca.pem"

# Regex pro filtrování aliasů, které chceme kontrolovat (uživatelské indexy)
# Předpokládá se, že uživatelské aliasy NIKDY nezačínají tečkou (.).
# Upravte tento regex tak, aby odpovídal vašim skutečným aliasům pro rollover.
ROLLOVER_ALIAS_REGEX="syslog-(apm|afm|unix|net|gtm|ips|proxy|asm)|winlogbeat|auditbeat|ntl|crp-ntl-tran|ntl-error|crp-ntl-secure|crp-ntl-securegdpr"

# Adresář pro ukládání denních statistik velikosti indexů
STATISTICS_DIR="/var/log/elasticsearch_statistics"

# Logovací soubor pro veškerý výstup skriptu (pro režim cron)
SCRIPT_LOG_FILE="${STATISTICS_DIR}/statistics.log"


# --- Inicializace a nastavení ---

# Příznak pro určení, zda má jít výstup na konzoli (true, pokud je předán parametr -show)
DISPLAY_TO_CONSOLE="false"

# Kontrola parametru -show
if [[ "$1" == "-show" ]]; then
  DISPLAY_TO_CONSOLE="true"
fi

# Před přesměrováním výstupu musíme zajistit existenci adresáře pro logy.
# Vytvoření adresáře pro statistiky (a tím i pro SCRIPT_LOG_FILE), pokud neexistuje
mkdir -p "${STATISTICS_DIR}"
if [ $? -ne 0 ]; then
  # Chyba při vytváření adresáře je kritická a musí být viditelná i bez přesměrování
  echo "Chyba: Nepodařilo se vytvořit adresář pro statistiky: ${STATISTICS_DIR}. Zkontrolujte oprávnění." >&2
  exit 1
fi

# Podmíněné přesměrování veškerého výstupu skriptu hned na začátku.
# Pokud je DISPLAY_TO_CONSOLE false, veškerý stdout/stderr bude přesměrován do SCRIPT_LOG_FILE.
# To zajistí, že při spuštění z cronu nebude na konzoli žádný výstup, pokud nedojde k chybě před tímto přesměrováním.
if [ "${DISPLAY_TO_CONSOLE}" == "false" ]; then
  exec >> "${SCRIPT_LOG_FILE}" 2>&1
fi

# Všechny následující 'echo' zprávy půjdou do správného cíle
# (konzole pro -show, nebo SCRIPT_LOG_FILE pro cron)
echo "=== Kontrola stavu Rollover Indexů a Dokumentů: $(date) ==="
echo "Adresář pro denní statistiky: ${STATISTICS_DIR}"
echo "Načítám informace o aliasech z Elasticsearch..."


# Kontrola existence .env souboru a načtení creds
if [ ! -f "${ENV_FILE}" ]; then
  echo "Chyba: Soubor .env nenalezen na ${ENV_FILE}. Ukončuji skript."
  exit 1
fi
source "${ENV_FILE}"

# Kontrola, zda jsou ELASTIC_USERNAME a ELASTIC_PASSWORD definovány
if [ -z "${ELASTIC_USERNAME}" ] || [ -z "${ELASTIC_PASSWORD}" ]; then
  echo "Chyba: ELASTIC_USERNAME nebo ELASTIC_PASSWORD nejsou nastaveny v ${ENV_FILE}. Ukončuji skript."
  exit 1
fi

# Curl možnosti s autentizací a certifikátem (tichý režim)
CURL_OPTS="-u ${ELASTIC_USERNAME}:${ELASTIC_PASSWORD} --cacert ${CA_CERT} -s"

# Dočasný soubor pro uložení JSON výstupu z aliasů
TEMP_ALIASES_DATA=$(mktemp)
trap "rm -f ${TEMP_ALIASES_DATA}" EXIT # Úklid dočasného souboru

# Získání aktuálního data pro názvy souborů statistik
CURRENT_DATE=$(date +%Y%m%d)

# --- Získání dat o aliasech ---

# Získání informací o všech aliasech
curl ${CURL_OPTS} -X GET "${ES_HOST}/_cat/aliases?format=json" > "${TEMP_ALIASES_DATA}"
if [ $? -ne 0 ]; then
  echo "Chyba: Selhalo načtení aliasů z Elasticsearch. Zkontrolujte připojení nebo oprávnění."
  exit 1
fi

# --- Zpracování dat a výstup ---

echo ""
echo "-----------------------------------------------------------------------------------------------------"
printf "%-25s %-35s %-15s %-15s\n" "Alias" "Aktivní Write Index" "Dokumentů" "Velikost (MB)"
echo "-----------------------------------------------------------------------------------------------------"

# Projdeme všechny aliasy a zkontrolujeme ty relevantní
# Filtr (.alias | startswith(\".\") | not) zajišťuje ignorování interních aliasů
jq -r \
  ".[] | select(
    (.alias | type == \"string\") and
    (.is_write_index | type == \"string\") and
    (.is_write_index == \"true\") and
    (.alias | startswith(\".\") | not) and
    (.alias | test(\"${ROLLOVER_ALIAS_REGEX}\"))
  ) | \"\(.alias)|\(.index)\"" "${TEMP_ALIASES_DATA}" | \
while IFS='|' read -r ALIAS ACTIVE_WRITE_INDEX; do
  # Získáme statistiky pro aktuální aktivní write index pomocí _stats API
  INDEX_STATS_JSON=$(curl ${CURL_OPTS} -X GET "${ES_HOST}/${ACTIVE_WRITE_INDEX}/_stats/store,docs" | jq -c '.')

  DOC_COUNT="N/A"
  STORE_SIZE="N/A"

  if [ -n "${INDEX_STATS_JSON}" ]; then
    # Získání počtu dokumentů
    # Použijeme `? // 0` pro vrácení 0, pokud je hodnota null nebo nenalezena
    DOC_COUNT=$(echo "${INDEX_STATS_JSON}" | jq -r --arg index_name "${ACTIVE_WRITE_INDEX}" '
      .indices[$index_name].total.docs.count? // 0
    ' 2>/dev/null)

    # Získání velikosti úložiště v MB
    # Použijeme `? // 0` pro vrácení 0, pokud je hodnota null nebo nenalezena
    RAW_STORE_SIZE_BYTES=$(echo "${INDEX_STATS_JSON}" | jq -r --arg index_name "${ACTIVE_WRITE_INDEX}" '
      .indices[$index_name].total.store.size_in_bytes? // 0
    ' 2>/dev/null)

    # Převod na MB a zaokrouhlení
    # Použijeme `0` jako default pro `bc` pokud je hodnota prázdná nebo nečíselná
    if [[ "${RAW_STORE_SIZE_BYTES}" =~ ^[0-9]+$ ]] && [ "${RAW_STORE_SIZE_BYTES}" -gt 0 ]; then
      STORE_SIZE=$(echo "scale=0; ${RAW_STORE_SIZE_BYTES} / (1024*1024)" | bc -l)
      # Zaokrouhlení nahoru, pokud je zbytek
      if (( $(echo "${RAW_STORE_SIZE_BYTES} % (1024*1024)" | bc) > 0 )); then # FIX: Changed RAW_STORE_BYTES to RAW_STORE_SIZE_BYTES
        STORE_SIZE=$((STORE_SIZE + 1))
      fi
    elif [ "${RAW_STORE_SIZE_BYTES}" -eq 0 ]; then
      STORE_SIZE="0"
    fi
  fi

  printf "%-25s %-35s %-15s %-15s\n" "${ALIAS}" "${ACTIVE_WRITE_INDEX}" "${DOC_COUNT}" "${STORE_SIZE}"

  # --- Zápis denní statistiky velikosti indexu ---
  # Vytvoření názvu souboru statistik
  STAT_FILENAME="${STATISTICS_DIR}/${ACTIVE_WRITE_INDEX}-${CURRENT_DATE}"

  # Pouze zapisujeme do souboru, pokud skript není spuštěn s -show
  if [ "${DISPLAY_TO_CONSOLE}" == "false" ]; then
    if [ "${STORE_SIZE}" == "N/A" ]; then
      echo "0" > "${STAT_FILENAME}"
    else
      echo "${STORE_SIZE}" > "${STAT_FILENAME}"
    fi
    echo "  Velikost indexu ${ACTIVE_WRITE_INDEX} (${STORE_SIZE} MB) uložena do: ${STAT_FILENAME}"
  fi

done

echo "-----------------------------------------------------------------------------------------------------"
echo "Kontrola dokončena."
echo "Poznámka: 'Velikost (MB)' je velikost úložiště (store.size) indexu zaokrouhlená na celé MB."

# Změněná závěrečná zpráva na základě parametru -show
if [ "${DISPLAY_TO_CONSOLE}" == "true" ]; then
  echo "Denní statistiky velikosti indexů se v tomto režimu NEUKLÁDAJÍ do souborů."
else
  echo "Denní statistiky velikosti indexů jsou uloženy v adresáři: ${STATISTICS_DIR}"
  echo "Kompletní výstup skriptu je k dispozici v souboru: ${SCRIPT_LOG_FILE}"
fi

exit 0

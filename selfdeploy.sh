#!/usr/bin/env bash
# selfdeploy.sh
# Анализ репозитория/директории.
# Внутри смотрит по модулям (manifest-файлы), снаружи отдаёт один
# агрегированный JSON по всему репозиторию.

# Allow probes to continue even when something is missing; keep pipefail for safety.
set -o pipefail

SCRIPT_NAME="$(basename "$0")"

# Директории, которые игнорируем при обходе
IGNORED_DIRS_EXPR='-name .git -o -name node_modules -o -name vendor -o -name .gradle -o -name target -o -name build -o -name .venv -o -name .tox -o -name .mypy_cache -o -name .pytest_cache -o -name .idea -o -name .vscode -o -name dist -o -name out -o -name coverage -o -name .terraform'

#######################################
# CLI
#######################################

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME analyze [--repo-url URL | --path DIR] [--keep-clone]

Options:
  --repo-url URL   Git-репозиторий (клонируется глубиной 1 во временную директорию)
  --path DIR       Локальная директория для анализа
  --keep-clone     Не удалять временный клон после анализа
  -h, --help       Показать эту справку
EOF
}

COMMAND=""
REPO_URL=""
LOCAL_PATH=""
KEEP_CLONE=0

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-url)
        REPO_URL="${2:-}"
        shift 2
        ;;
      --path)
        LOCAL_PATH="${2:-}"
        shift 2
        ;;
      --keep-clone)
        KEEP_CLONE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$COMMAND" != "analyze" ]]; then
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
  fi

  if [[ -n "$REPO_URL" && -n "$LOCAL_PATH" ]]; then
    echo "Use either --repo-url or --path, not both." >&2
    exit 1
  fi
  if [[ -z "$REPO_URL" && -z "$LOCAL_PATH" ]]; then
    echo "You must specify either --repo-url or --path." >&2
    exit 1
  fi
}

#######################################
# Общие утилиты
#######################################

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

is_numeric_version() {
  local v="$1"
  # Accept simple numeric versions like 17, 1.2 or 1.20.4 (multiple segments).
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

extract_xml_tag_value() {
  local file="$1"
  local tag="$2"
  awk -v t="$tag" 'BEGIN{IGNORECASE=1}
    match($0, "<[^>]*" t "[^>]*>[ \t]*([^<]+)<", a) { print a[1]; exit }
  ' "$file" 2>/dev/null || true
}

extract_gradle_compat_version() {
  local file="$1"
  awk 'BEGIN{IGNORECASE=1}
    match($0, /sourceCompatibility[ ="]+([^" \t]+)/, a) { print a[1]; exit }
    match($0, /targetCompatibility[ ="]+([^" \t]+)/, a) { print a[1]; exit }
  ' "$file" 2>/dev/null || true
}

extract_gradle_toolchain_version() {
  local file="$1"
  awk 'BEGIN{IGNORECASE=1}
    match($0, /JavaLanguageVersion\.of\(([^\)]+)\)/, a) { print a[1]; exit }
    match($0, /languageVersion[ \t]*=[ \t]*JavaLanguageVersion\.of\(([^\)]+)\)/, a) { print a[1]; exit }
    match($0, /languageVersion\.set\(JavaLanguageVersion\.of\(([^\)]+)\)\)/, a) { print a[1]; exit }
  ' "$file" 2>/dev/null || true
}

extract_gradle_inline_java_version() {
  local file="$1"
  awk 'BEGIN{IGNORECASE=1}
    match($0, /JavaVersion\.VERSION_([0-9]+)/, a) { print a[1]; exit }
    match($0, /javaVersion[ \t]*=[ \t]*JavaVersion\.VERSION_([0-9]+)/, a) { print a[1]; exit }
  ' "$file" 2>/dev/null || true
}

extract_gradle_properties_java_version_in_file() {
  local file="$1"
  awk 'BEGIN{IGNORECASE=1}
    match($0, /^[ \t]*(javaVersion|minRuntimeVersion|minimumRuntimeVersion|runtimeJavaVersion)[ \t]*=[ \t]*([0-9]+(\.[0-9]+)?)/, a) { print a[2]; exit }
  ' "$file" 2>/dev/null || true
}

extract_gradle_properties_java_version() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/gradle.properties" ]]; then
      local v
      v="$(extract_gradle_properties_java_version_in_file "$dir/gradle.properties")"
      [[ -n "${v:-}" ]] && { echo "$v"; return; }
    fi
    dir="$(cd "$dir/.." 2>/dev/null && pwd)"
  done
}

extract_gradle_java_version_upwards() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    local gf=""
    if [[ -f "$dir/build.gradle.kts" ]]; then
      gf="$dir/build.gradle.kts"
    elif [[ -f "$dir/build.gradle" ]]; then
      gf="$dir/build.gradle"
    fi
    if [[ -n "$gf" ]]; then
      local v
      v="$(extract_gradle_toolchain_version "$gf")"
      [[ -z "${v:-}" ]] && v="$(extract_gradle_inline_java_version "$gf")"
      [[ -z "${v:-}" ]] && v="$(extract_gradle_compat_version "$gf")"
      if [[ -n "${v:-}" ]]; then
        echo "$v"
        return
      fi
    fi
    dir="$(cd "$dir/.." 2>/dev/null && pwd)"
  done
}

extract_java_version_grep_repo() {
  local dir="$1"
  local v=""
  local files

  files="$(find "$dir" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'settings.gradle' -o -name 'settings.gradle.kts' -o -name 'gradle.properties' -o -name 'pom.xml' \) -print 2>/dev/null || true)"
  if [[ -n "$files" ]]; then
    v="$(printf '%s\n' "$files" | xargs -I{} sh -c "grep -m1 -o -E 'JavaVersion\\.VERSION_[0-9]+' '{}' || true" | head -n1 | sed -E 's/.*VERSION_([0-9]+).*/\\1/' || true)"
  fi
  [[ -n "${v:-}" ]] && { echo "$v"; return; }

  files="$(find "$dir" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( -name 'gradle.properties' -o -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'settings.gradle' -o -name 'settings.gradle.kts' \) -print 2>/dev/null || true)"
  if [[ -n "$files" ]]; then
    v="$(printf '%s\n' "$files" | xargs -I{} sh -c "grep -m1 -E 'java(Version|\\.version|_version|RuntimeVersion|minRuntimeVersion)[^0-9]*[ =:]?[ \\t]*[0-9]{1,2}' '{}' || true" | head -n1 | sed -E 's/.*([0-9]{1,2}).*/\\1/' || true)"
  fi
  [[ -n "${v:-}" ]] && echo "$v"
}

extract_maven_java_version_in_file() {
  local file="$1"
  local v=""
  local tag ref

  # primary tags (release/source/target/java.version), namespace-insensitive
  v="$(awk 'BEGIN{IGNORECASE=1}
    match($0, /<[^>]*release[^>]*>[ \t]*([^<[:space:]]+)/, a) { print a[1]; exit }
    match($0, /<[^>]*source[^>]*>[ \t]*([^<[:space:]]+)/, a) { print a[1]; exit }
    match($0, /<[^>]*target[^>]*>[ \t]*([^<[:space:]]+)/, a) { print a[1]; exit }
    match($0, /<[^>]*java\.version[^>]*>[ \t]*([^<[:space:]]+)/, a) { print a[1]; exit }
  ' "$file" 2>/dev/null || true)"

  if [[ -n "$v" && ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$v" =~ ^\$\{[^}]+\}$ ]]; then
    # Ignore non-numeric, non-property values (e.g. boolean <release>true</release>)
    v=""
  fi

  if [[ "$v" =~ ^\$\{([^}]+)\}$ ]]; then
    ref="${BASH_REMATCH[1]}"
    v="$(awk -v p="$ref" 'BEGIN{IGNORECASE=1}
      match($0, "<[^>]*" p "[^>]*>[ \t]*([^<[:space:]]+)", a) { print a[1]; exit }
    ' "$file" 2>/dev/null || true)"
  fi

  if [[ -z "$v" || "$v" =~ ^\$\{ ]]; then
    v="$(awk 'BEGIN{IGNORECASE=1}
      match($0, /<[^>]*java[^>]*>[ \t]*([0-9]+(\.[0-9]+)?)/, a) { print a[1]; exit }
      match($0, /<[^>]*target[^>]*>[ \t]*([0-9]+(\.[0-9]+)?)/, a) { print a[1]; exit }
    ' "$file" 2>/dev/null || true)"
  fi

  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$v"
}

extract_maven_java_version() {
  local file="$1"
  local attempts=0
  local max_up=5
  local dir
  dir="$(dirname "$file")"
  while [[ $attempts -lt $max_up ]]; do
    attempts=$((attempts+1))
    local val
    val="$(extract_maven_java_version_in_file "$file")"
    [[ -n "$val" ]] && { echo "$val"; return; }
    dir="$(cd "$dir/.." 2>/dev/null && pwd)"
    [[ -z "$dir" || "$dir" == "/" ]] && break
    if [[ -f "$dir/pom.xml" ]]; then
      file="$dir/pom.xml"
      continue
    else
      break
    fi
  done
}

extract_ant_java_version() {
  local file="$1"
  awk 'BEGIN{IGNORECASE=1}
    match($0, /property[^>]*name="[^"]*(java|target)[^"]*"[^>]*value="([0-9]+(\.[0-9]+)?)"/, a) { print a[2]; exit }
  ' "$file" 2>/dev/null || true
}

#######################################
# Dockerfile
#######################################

has_dockerfile() {
  local root="$1"
  if find "$root" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'Dockerfile' -print -quit >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

#######################################
# Модули (монореп внутри, наружу – агрегат)
#######################################

declare -a MODULE_DIRS=()
declare -a MODULE_RELS=()

add_module() {
  local root="$1"
  local dir="$2"

  local i
  for i in "${MODULE_DIRS[@]}"; do
    [[ "$i" == "$dir" ]] && return 0
  done

  local rel="${dir#$root/}"
  if [[ "$rel" == "$root" || -z "$rel" ]]; then
    rel="."
  fi

  MODULE_DIRS+=("$dir")
  MODULE_RELS+=("$rel")
}

discover_modules() {
  local root="$1"

  MODULE_DIRS=()
  MODULE_RELS=()

  local manifest_expr='-name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name build.xml -o -name go.mod -o -name Gemfile -o -name package.json -o -name pyproject.toml -o -name requirements.txt -o -name Pipfile -o -name setup.py'

  while IFS= read -r mf; do
    local dir
    dir="$(dirname "$mf")"
    add_module "$root" "$dir"
  done < <(find "$root" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( $manifest_expr \) -print 2>/dev/null || true)

  # если manifest-ов нет – считаем весь root одним модулем
  if [[ ${#MODULE_DIRS[@]} -eq 0 ]]; then
    add_module "$root" "$root"
  fi
}

#######################################
# Состояние детекции по модулю
#######################################

LANGUAGE="unknown"
FRAMEWORK="unknown"
BUILD_TOOL="unknown"
TEST_TOOL="unknown"
ARTIFACT_TYPE="unknown"
RUNTIME_VERSION="unknown"
BEST_SCORE=-1
CURRENT_MODULE_REL=""
ENV_FILES_JSON="[]"
LICENSES_JSON="[]"
CI_GITLAB="false"
CI_GITHUB="false"

declare -a NOTES=()
declare -a RUNTIME_CANDIDATES=()
declare -a RUNTIME_CANDIDATE_SCORES=()
declare -a BUILD_CMD_CANDIDATES=()
declare -a BUILD_CMD_CANDIDATE_SCORES=()
declare -a TEST_CMD_CANDIDATES=()
declare -a TEST_CMD_CANDIDATE_SCORES=()

reset_detection_state() {
  LANGUAGE="unknown"
  FRAMEWORK="unknown"
  BUILD_TOOL="unknown"
  TEST_TOOL="unknown"
  ARTIFACT_TYPE="unknown"
  RUNTIME_VERSION="unknown"
  BEST_SCORE=-1
  NOTES=()
  RUNTIME_CANDIDATES=()
  RUNTIME_CANDIDATE_SCORES=()
  BUILD_CMD_CANDIDATES=()
  BUILD_CMD_CANDIDATE_SCORES=()
  TEST_CMD_CANDIDATES=()
  TEST_CMD_CANDIDATE_SCORES=()
}

add_note() {
  local note="$1"
  local n
  for n in "${NOTES[@]}"; do
    [[ "$n" == "$note" ]] && return 0
  done
  NOTES+=("$note")
}

add_runtime_candidate() {
  local rv="$1"
  local score="$2"
  [[ "$rv" == "unknown" || -z "$rv" ]] && return 0
  local rv_num="$rv"
  local prefix
  for prefix in java go node python ruby; do
    if [[ "$rv" == "$prefix-"* ]]; then
      rv_num="${rv#"$prefix-"}"
      break
    fi
  done
  is_numeric_version "$rv_num" || return 0
  local i
  for i in "${!RUNTIME_CANDIDATES[@]}"; do
    if [[ "${RUNTIME_CANDIDATES[$i]}" == "$rv" ]]; then
      RUNTIME_CANDIDATE_SCORES[$i]=$(( RUNTIME_CANDIDATE_SCORES[$i] + score ))
      return 0
    fi
  done
  RUNTIME_CANDIDATES+=("$rv")
  RUNTIME_CANDIDATE_SCORES+=("$score")
}

add_build_cmd_candidate() {
  local cmd="$1"
  local score="$2"
  [[ -z "$cmd" ]] && return 0
  local i
  for i in "${!BUILD_CMD_CANDIDATES[@]}"; do
    if [[ "${BUILD_CMD_CANDIDATES[$i]}" == "$cmd" ]]; then
      BUILD_CMD_CANDIDATE_SCORES[$i]=$(( BUILD_CMD_CANDIDATE_SCORES[$i] + score ))
      return 0
    fi
  done
  BUILD_CMD_CANDIDATES+=("$cmd")
  BUILD_CMD_CANDIDATE_SCORES+=("$score")
}

add_test_cmd_candidate() {
  local cmd="$1"
  local score="$2"
  [[ -z "$cmd" ]] && return 0
  local i
  for i in "${!TEST_CMD_CANDIDATES[@]}"; do
    if [[ "${TEST_CMD_CANDIDATES[$i]}" == "$cmd" ]]; then
      TEST_CMD_CANDIDATE_SCORES[$i]=$(( TEST_CMD_CANDIDATE_SCORES[$i] + score ))
      return 0
    fi
  done
  TEST_CMD_CANDIDATES+=("$cmd")
  TEST_CMD_CANDIDATE_SCORES+=("$score")
}

consider_candidate() {
  local lang="$1"
  local framework="$2"
  local build_tool="$3"
  local test_tool="$4"
  local artifact_type="$5"
  local score="$6"
  # desc="$7" – сейчас не используется на уровне модуля

  if (( score > BEST_SCORE )); then
    BEST_SCORE="$score"
    LANGUAGE="$lang"
    FRAMEWORK="$framework"
    BUILD_TOOL="$build_tool"
    TEST_TOOL="$test_tool"
    ARTIFACT_TYPE="$artifact_type"
  fi
}

# Utility: pick best-scored candidate from parallel arrays, fallback if empty.
best_scored_value() {
  local -n names_arr="$1"
  local -n scores_arr="$2"
  local fallback="$3"

  local best="$fallback"
  local best_score=-1
  local i
  for i in "${!names_arr[@]}"; do
    if (( scores_arr[$i] > best_score )) && [[ -n "${names_arr[$i]}" ]]; then
      best_score="${scores_arr[$i]}"
      best="${names_arr[$i]}"
    fi
  done
  echo "$best"
}

append_unique() {
  local -n arr="$1"
  local val="$2"
  local i
  for i in "${arr[@]}"; do
    [[ "$i" == "$val" ]] && return 0
  done
  arr+=("$val")
}

#######################################
# Агрегация по репозиторию
#######################################

declare -a REPO_LANGS=()
declare -a REPO_LANG_SCORES=()
declare -a REPO_FRAMEWORKS=()
declare -a REPO_FRAMEWORK_SCORES=()
declare -a REPO_BUILD_TOOLS=()
declare -a REPO_BUILD_TOOL_SCORES=()
declare -a REPO_TEST_TOOLS=()
declare -a REPO_TEST_TOOL_SCORES=()
declare -a REPO_ARTIFACT_TYPES=()
declare -a REPO_ARTIFACT_TYPE_SCORES=()
declare -a REPO_RUNTIME_VERSIONS=()
declare -a REPO_RUNTIME_VERSION_SCORES=()
declare -a REPO_BUILD_CMDS=()
declare -a REPO_BUILD_CMD_SCORES=()
declare -a REPO_TEST_CMDS=()
declare -a REPO_TEST_CMD_SCORES=()
declare -a REPO_NOTES=()
declare -a REPO_PACKAGE_MANAGERS=()
declare -a REPO_PACKAGE_MANAGER_SCORES=()
declare -a REPO_PORTS=()
declare -a REPO_PORT_SCORES=()
declare -a MODULE_JSONS=()

repo_reset() {
  REPO_LANGS=()
  REPO_LANG_SCORES=()
  REPO_FRAMEWORKS=()
  REPO_FRAMEWORK_SCORES=()
  REPO_BUILD_TOOLS=()
  REPO_BUILD_TOOL_SCORES=()
  REPO_TEST_TOOLS=()
  REPO_TEST_TOOL_SCORES=()
  REPO_ARTIFACT_TYPES=()
  REPO_ARTIFACT_TYPE_SCORES=()
  REPO_RUNTIME_VERSIONS=()
  REPO_RUNTIME_VERSION_SCORES=()
  REPO_BUILD_CMDS=()
  REPO_BUILD_CMD_SCORES=()
  REPO_TEST_CMDS=()
  REPO_TEST_CMD_SCORES=()
  REPO_NOTES=()
  REPO_PACKAGE_MANAGERS=()
  REPO_PACKAGE_MANAGER_SCORES=()
  REPO_PORTS=()
  REPO_PORT_SCORES=()
  MODULE_JSONS=()
}

repo_agg_lang() {
  local lang="$1"
  local score="$2"
  [[ "$lang" == "unknown" ]] && return 0
  local i
  for i in "${!REPO_LANGS[@]}"; do
    if [[ "${REPO_LANGS[$i]}" == "$lang" ]]; then
      REPO_LANG_SCORES[$i]=$(( REPO_LANG_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_LANGS+=("$lang")
  REPO_LANG_SCORES+=("$score")
}

repo_agg_framework() {
  local fw="$1"
  local score="$2"
  [[ "$fw" == "unknown" || "$fw" == "none" ]] && return 0
  local i
  for i in "${!REPO_FRAMEWORKS[@]}"; do
    if [[ "${REPO_FRAMEWORKS[$i]}" == "$fw" ]]; then
      REPO_FRAMEWORK_SCORES[$i]=$(( REPO_FRAMEWORK_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_FRAMEWORKS+=("$fw")
  REPO_FRAMEWORK_SCORES+=("$score")
}

repo_agg_build_tool() {
  local bt="$1"
  local score="$2"
  [[ "$bt" == "unknown" ]] && return 0
  local i
  for i in "${!REPO_BUILD_TOOLS[@]}"; do
    if [[ "${REPO_BUILD_TOOLS[$i]}" == "$bt" ]]; then
      REPO_BUILD_TOOL_SCORES[$i]=$(( REPO_BUILD_TOOL_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_BUILD_TOOLS+=("$bt")
  REPO_BUILD_TOOL_SCORES+=("$score")
}

repo_agg_test_tool() {
  local tt="$1"
  local score="$2"
  [[ "$tt" == "unknown" ]] && return 0
  local i
  for i in "${!REPO_TEST_TOOLS[@]}"; do
    if [[ "${REPO_TEST_TOOLS[$i]}" == "$tt" ]]; then
      REPO_TEST_TOOL_SCORES[$i]=$(( REPO_TEST_TOOL_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_TEST_TOOLS+=("$tt")
  REPO_TEST_TOOL_SCORES+=("$score")
}

repo_agg_artifact_type() {
  local at="$1"
  local score="$2"
  [[ "$at" == "unknown" ]] && return 0
  local i
  for i in "${!REPO_ARTIFACT_TYPES[@]}"; do
    if [[ "${REPO_ARTIFACT_TYPES[$i]}" == "$at" ]]; then
      REPO_ARTIFACT_TYPE_SCORES[$i]=$(( REPO_ARTIFACT_TYPE_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_ARTIFACT_TYPES+=("$at")
  REPO_ARTIFACT_TYPE_SCORES+=("$score")
}

repo_agg_package_manager() {
  local pm="$1"
  local score="$2"
  [[ -z "$pm" || "$pm" == "unknown" ]] && return 0
  local i
  for i in "${!REPO_PACKAGE_MANAGERS[@]}"; do
    if [[ "${REPO_PACKAGE_MANAGERS[$i]}" == "$pm" ]]; then
      REPO_PACKAGE_MANAGER_SCORES[$i]=$(( REPO_PACKAGE_MANAGER_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_PACKAGE_MANAGERS+=("$pm")
  REPO_PACKAGE_MANAGER_SCORES+=("$score")
}

repo_agg_port() {
  local port="$1"
  local score="$2"
  [[ -z "$port" ]] && return 0
  local i
  for i in "${!REPO_PORTS[@]}"; do
    if [[ "${REPO_PORTS[$i]}" == "$port" ]]; then
      REPO_PORT_SCORES[$i]=$(( REPO_PORT_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_PORTS+=("$port")
  REPO_PORT_SCORES+=("$score")
}

repo_agg_runtime_version() {
  local rv="$1"
  local score="$2"
  [[ "$rv" == "unknown" || -z "$rv" ]] && return 0
  local rv_num="${rv#java-}"
  if [[ "$rv" == "$rv_num" ]]; then
    rv_num="$rv"
  fi
  is_numeric_version "$rv_num" || return 0
  local i
  for i in "${!REPO_RUNTIME_VERSIONS[@]}"; do
    if [[ "${REPO_RUNTIME_VERSIONS[$i]}" == "$rv" ]]; then
      REPO_RUNTIME_VERSION_SCORES[$i]=$(( REPO_RUNTIME_VERSION_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_RUNTIME_VERSIONS+=("$rv")
  REPO_RUNTIME_VERSION_SCORES+=("$score")
}

repo_agg_build_cmd() {
  local cmd="$1"
  local score="$2"
  [[ -z "$cmd" ]] && return 0
  local i
  for i in "${!REPO_BUILD_CMDS[@]}"; do
    if [[ "${REPO_BUILD_CMDS[$i]}" == "$cmd" ]]; then
      REPO_BUILD_CMD_SCORES[$i]=$(( REPO_BUILD_CMD_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_BUILD_CMDS+=("$cmd")
  REPO_BUILD_CMD_SCORES+=("$score")
}

repo_agg_test_cmd() {
  local cmd="$1"
  local score="$2"
  [[ -z "$cmd" ]] && return 0
  local i
  for i in "${!REPO_TEST_CMDS[@]}"; do
    if [[ "${REPO_TEST_CMDS[$i]}" == "$cmd" ]]; then
      REPO_TEST_CMD_SCORES[$i]=$(( REPO_TEST_CMD_SCORES[$i] + score ))
      return 0
    fi
  done
  REPO_TEST_CMDS+=("$cmd")
  REPO_TEST_CMD_SCORES+=("$score")
}

extract_ports_from_file() {
  local file="$1"
  local -a found=()
  while IFS= read -r line; do
    line="${line%%#*}"
    if [[ "$line" =~ ^[Pp][Oo][Rr][Tt][=:[:space:]]*([0-9]{2,5}) ]]; then
      append_unique found "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^EXPOSE[[:space:]]+([0-9]{2,5}) ]]; then
      append_unique found "${BASH_REMATCH[1]}"
    fi
  done < "$file"
  printf '%s\n' "${found[@]}"
}

detect_module_ports() {
  local module_dir="$1"
  local -a ports=()

  while IFS= read -r df; do
    [[ -z "$df" ]] && continue
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      append_unique ports "$p"
    done < <(extract_ports_from_file "$df")
  done < <(find "$module_dir" -maxdepth 2 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -iname 'dockerfile' -print 2>/dev/null || true)

  while IFS= read -r envf; do
    [[ -z "$envf" ]] && continue
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      append_unique ports "$p"
    done < <(extract_ports_from_file "$envf")
  done < <(find "$module_dir" -maxdepth 3 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( -name '.env' -o -name '.env.example' -o -name 'application.properties' -o -name 'application.yml' -o -name 'application.yaml' \) -print 2>/dev/null || true)

  printf '%s\n' "${ports[@]}"
}

record_module() {
  local module_dir="$1"
  local module_rel="${CURRENT_MODULE_REL:-.}"

  local runtime_best
  runtime_best="$(best_scored_value RUNTIME_CANDIDATES RUNTIME_CANDIDATE_SCORES "$RUNTIME_VERSION")"
  local build_cmd_best
  build_cmd_best="$(best_scored_value BUILD_CMD_CANDIDATES BUILD_CMD_CANDIDATE_SCORES "")"
  local test_cmd_best
  test_cmd_best="$(best_scored_value TEST_CMD_CANDIDATES TEST_CMD_CANDIDATE_SCORES "")"

  local package_manager="unknown"
  case "$BUILD_TOOL" in
    npm|yarn|pnpm|poetry|pipenv|pip|bundler|maven|gradle|ant|go)
      package_manager="$BUILD_TOOL"
      ;;
  esac

  local -a ports_arr=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    append_unique ports_arr "$p"
    repo_agg_port "$p" "$BEST_SCORE"
  done < <(detect_module_ports "$module_dir")

  local ports_json="["
  local idx=0
  for p in "${ports_arr[@]}"; do
    [[ $idx -gt 0 ]] && ports_json+=", "
    ports_json+="\"$(json_escape "$p")\""
    idx=$((idx+1))
  done
  ports_json+="]"

  local notes_json="["
  for i in "${!NOTES[@]}"; do
    [[ $i -gt 0 ]] && notes_json+=", "
    notes_json+="\"$(json_escape "${NOTES[$i]}")\""
  done
  notes_json+="]"

  local dockerfiles_mod_json="["
  idx=0
  while IFS= read -r df; do
    [[ -z "$df" ]] && continue
    [[ $idx -gt 0 ]] && dockerfiles_mod_json+=", "
    dockerfiles_mod_json+="\"$(json_escape "$df")\""
    idx=$((idx+1))
  done < <(find "$module_dir" -maxdepth 2 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -iname 'dockerfile' -print 2>/dev/null || true)
  dockerfiles_mod_json+="]"

  repo_agg_package_manager "$package_manager" "$BEST_SCORE"

  local module_json
  module_json="$(cat <<EOF
  {
    "path": "$(json_escape "$module_rel")",
    "language": "$(json_escape "$LANGUAGE")",
    "framework": "$(json_escape "$FRAMEWORK")",
    "build_tool": "$(json_escape "$BUILD_TOOL")",
    "test_tool": "$(json_escape "$TEST_TOOL")",
    "artifact_type": "$(json_escape "$ARTIFACT_TYPE")",
    "runtime_version": "$(json_escape "$runtime_best")",
    "build_command": "$(json_escape "$build_cmd_best")",
    "test_command": "$(json_escape "$test_cmd_best")",
    "package_manager": "$(json_escape "$package_manager")",
    "ports": $ports_json,
    "dockerfiles": $dockerfiles_mod_json,
    "notes": $notes_json
  }
EOF
)"

  MODULE_JSONS+=("$module_json")
}

repo_add_note() {
  local note="$1"
  local n
  for n in "${REPO_NOTES[@]}"; do
    [[ "$n" == "$note" ]] && return 0
  done
  REPO_NOTES+=("$note")
}

aggregate_current_module_into_repo() {
  local score="$BEST_SCORE"
  (( score < 0 )) && score=0

  repo_agg_lang "$LANGUAGE" "$score"
  repo_agg_framework "$FRAMEWORK" "$score"
  repo_agg_build_tool "$BUILD_TOOL" "$score"
  repo_agg_test_tool "$TEST_TOOL" "$score"
  repo_agg_artifact_type "$ARTIFACT_TYPE" "$score"

  local n
  for n in "${NOTES[@]}"; do
    repo_add_note "$n"
  done

  local i
  for i in "${!RUNTIME_CANDIDATES[@]}"; do
    repo_agg_runtime_version "${RUNTIME_CANDIDATES[$i]}" "${RUNTIME_CANDIDATE_SCORES[$i]}"
  done
  # Fallback: if no candidates were added but we still inferred a runtime_version, record it.
  if [[ "$RUNTIME_VERSION" != "unknown" && -n "$RUNTIME_VERSION" ]]; then
    repo_agg_runtime_version "$RUNTIME_VERSION" "$score"
  fi

  for i in "${!BUILD_CMD_CANDIDATES[@]}"; do
    repo_agg_build_cmd "${BUILD_CMD_CANDIDATES[$i]}" "${BUILD_CMD_CANDIDATE_SCORES[$i]}"
  done
  for i in "${!TEST_CMD_CANDIDATES[@]}"; do
    repo_agg_test_cmd "${TEST_CMD_CANDIDATES[$i]}" "${TEST_CMD_CANDIDATE_SCORES[$i]}"
  done
}

#######################################
# Детекторы стеков
#######################################

# Go
detect_go() {
  local module_dir="$1"

  local gomod="$module_dir/go.mod"
  [[ -f "$gomod" ]] || return 0

  local score=70
  add_note "Go: go.mod present"
  local runtime_version="unknown"
  local gover
  gover="$(grep -m1 -E '^go [0-9]+(\\.[0-9]+)?' "$gomod" | awk '{print $2}' || true)"
  if [[ -n "${gover:-}" ]]; then
    runtime_version="go-$gover"
    add_note "Go: version $gover from go.mod"
  fi

  if find "$module_dir" -maxdepth 4 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'main.go' -print -quit >/dev/null 2>&1; then
    score=$((score+10))
    add_note "Go: main.go present"
  fi

  if find "$module_dir" -maxdepth 6 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name '*_test.go' -print -quit >/dev/null 2>&1; then
    score=$((score+5))
    add_note "Go: *_test.go present"
  fi

  add_build_cmd_candidate "go build ./..." "$score"
  add_test_cmd_candidate "go test ./..." "$score"
  add_runtime_candidate "$runtime_version" "$score"

  local prev_score="$BEST_SCORE"
  consider_candidate "go" "none" "go" "go test" "binary" "$score" "Go module"
  if (( BEST_SCORE > prev_score )); then
    RUNTIME_VERSION="$runtime_version"
  fi
}

# Ruby / Rails (усиленный вес Rails)
detect_ruby() {
  local module_dir="$1"

  local has_gem=0
  [[ -f "$module_dir/Gemfile" ]] && has_gem=1
  [[ -f "$module_dir/Gemfile.lock" ]] && has_gem=1
  (( has_gem == 1 )) || return 0

  local framework="ruby-generic"
  local score=65
  add_note "Ruby: Gemfile present"

  local has_rails_marker=0
  if [[ -x "$module_dir/bin/rails" ]] || \
     [[ -f "$module_dir/config.ru" ]] || \
     [[ -d "$module_dir/app/controllers" ]] || \
     [[ -d "$module_dir/app/models" ]] || \
     [[ -f "$module_dir/config/application.rb" ]]; then
    has_rails_marker=1
  fi

  if (( has_rails_marker == 1 )); then
    framework="rails"
    score=$((score+25))
    add_note "Ruby: Rails markers (bin/rails/config.ru/app/controllers/app/models/config/application.rb)"
  fi

  if [[ -d "$module_dir/spec" ]]; then
    score=$((score+5))
    add_note "Ruby: spec/ directory"
  fi

  consider_candidate "ruby" "$framework" "bundler" "rspec" "app" "$score" "Ruby module"
}

# Node.js / TypeScript
detect_node() {
  local module_dir="$1"

  local pkg=""
  if [[ -f "$module_dir/package.json" ]]; then
    pkg="$module_dir/package.json"
  else
    pkg="$(find "$module_dir" -maxdepth 4 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'package.json' -print 2>/dev/null | head -n1 || true)"
  fi

  [[ -n "$pkg" ]] || return 0

  local pkg_dir
  pkg_dir="$(dirname "$pkg")"

  local language="javascript"
  if find "$module_dir" -maxdepth 4 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'tsconfig.json' -print -quit >/dev/null 2>&1; then
    language="typescript"
    add_note "Node: tsconfig.json present"
  fi

  local build_tool="npm"
  [[ -f "$pkg_dir/yarn.lock" ]] && build_tool="yarn"
  [[ -f "$pkg_dir/pnpm-lock.yaml" ]] && build_tool="pnpm"

  local content
  content="$(tr -d $'\n\r\t ' < "$pkg" | tr '[:upper:]' '[:lower:]')"
  local runtime_version="unknown"
  if [[ -f "$pkg_dir/.nvmrc" ]]; then
    local nvm_node
    nvm_node="$(head -n1 "$pkg_dir/.nvmrc" | tr -d '[:space:]')"
    if [[ -n "${nvm_node:-}" ]]; then
      runtime_version="node-$nvm_node"
      add_note "Node: version $nvm_node from .nvmrc"
    fi
  fi
  if [[ "$runtime_version" == "unknown" ]]; then
    local nodever
    nodever="$(grep -o '"node":"[^"]*"' <<<"$content" | head -n1 | cut -d'"' -f4 || true)"
    if [[ -n "${nodever:-}" ]]; then
      runtime_version="node-$nodever"
      add_note "Node: engines.node=$nodever"
    fi
  fi

  local framework="node-generic"

  if grep -q '"@nestjs/core"' <<<"$content" || grep -q '"@nestjs/common"' <<<"$content"; then
    framework="nestjs"
  elif grep -q '"next"' <<<"$content"; then
    framework="nextjs"
  elif grep -q '"express"' <<<"$content"; then
    framework="express"
  elif grep -q '"react"' <<<"$content" || grep -q '"react-dom"' <<<"$content"; then
    framework="react"
  elif grep -q '"vue"' <<<"$content" || grep -q '"@vue/' <<<"$content"; then
    framework="vue"
  fi

  if grep -q '"scripts":{[^}]*"next":"next' <<<"$content"; then
    framework="nextjs"
    add_note "Node: scripts[next] uses next"
  elif grep -q '"scripts":{[^}]*"dev":"next' <<<"$content"; then
    framework="nextjs"
    add_note "Node: scripts[dev] uses next"
  elif grep -q '"scripts":{[^}]*"start":"react-scripts' <<<"$content"; then
    framework="react"
    add_note "Node: scripts[start] uses react-scripts"
  fi

  local score=60
  add_note "Node: package.json at $pkg (pm=$build_tool)"

  if [[ "$pkg_dir" == "$module_dir" ]]; then
    score=$((score+10))
  else
    score=$((score-5))
    add_note "Node: package.json not at module root"
  fi

  if [[ "$language" == "typescript" ]]; then
    score=$((score+5))
  fi

  if [[ "$framework" != "node-generic" ]]; then
    score=$((score+10))
    add_note "Node: framework=$framework"
  fi

  # Build/test commands from package.json scripts
  local build_cmd=""
  local test_cmd=""
  if grep -q '\"build\":\"' <<<"$content"; then
    build_cmd="$build_tool run build"
  fi
  if grep -q '\"test\":\"' <<<"$content"; then
    test_cmd="$build_tool test"
  fi
  add_build_cmd_candidate "$build_cmd" "$score"
  add_test_cmd_candidate "$test_cmd" "$score"

  add_runtime_candidate "$runtime_version" "$score"

  local prev_score="$BEST_SCORE"
  consider_candidate "$language" "$framework" "$build_tool" "jest" "node-app" "$score" "Node.js/TypeScript module"
  if (( BEST_SCORE > prev_score )); then
    RUNTIME_VERSION="$runtime_version"
  fi
}

# Python (c учётом ASGI/WSGI generic)
detect_python() {
  local module_dir="$1"

  local has_marker=0
  local framework="none"
  local build_tool="pip"
  local test_tool="pytest"
  local artifact_type="wheel"
  local runtime_version="unknown"

  if [[ -f "$module_dir/pyproject.toml" ]]; then
    has_marker=1
    add_note "Python: pyproject.toml present"
    if grep -qi 'tool.poetry' "$module_dir/pyproject.toml" 2>/dev/null; then
      build_tool="poetry"
      add_note "Python: build_tool=poetry"
    fi
    if grep -qi 'django' "$module_dir/pyproject.toml" 2>/dev/null; then
      framework="django"
    elif grep -qi 'fastapi' "$module_dir/pyproject.toml" 2>/dev/null; then
      framework="fastapi"
    elif grep -qi 'flask' "$module_dir/pyproject.toml" 2>/dev/null; then
      framework="flask"
    fi
  fi

  if [[ -f "$module_dir/requirements.txt" ]]; then
    has_marker=1
    add_note "Python: requirements.txt present"
    if [[ "$framework" == "none" ]]; then
      if grep -qi 'django' "$module_dir/requirements.txt" 2>/dev/null; then
        framework="django"
      elif grep -qi 'fastapi' "$module_dir/requirements.txt" 2>/dev/null; then
        framework="fastapi"
      elif grep -qi 'flask' "$module_dir/requirements.txt" 2>/dev/null; then
        framework="flask"
      fi
    fi
  fi

  if [[ -f "$module_dir/Pipfile" ]]; then
    has_marker=1
    build_tool="pipenv"
    add_note "Python: Pipfile present (pipenv)"
    if [[ "$framework" == "none" ]]; then
      if grep -qi 'django' "$module_dir/Pipfile" 2>/dev/null; then
        framework="django"
      elif grep -qi 'fastapi' "$module_dir/Pipfile" 2>/dev/null; then
        framework="fastapi"
      elif grep -qi 'flask' "$module_dir/Pipfile" 2>/dev/null; then
        framework="flask"
      fi
    fi
  fi

  if [[ -f "$module_dir/setup.py" ]]; then
    has_marker=1
    add_note "Python: setup.py present"
  fi

  if [[ -f "$module_dir/.python-version" ]]; then
    local pyver_file
    pyver_file="$(head -n1 "$module_dir/.python-version" | tr -d '[:space:]')"
    if [[ -n "${pyver_file:-}" ]]; then
      runtime_version="python-$pyver_file"
      add_note "Python: version $pyver_file from .python-version"
    fi
  fi
  if [[ "$runtime_version" == "unknown" && -f "$module_dir/pyproject.toml" ]]; then
    local pyver_req
    local py_line
    py_line="$(grep -m1 -E 'requires-python[[:space:]]*=' "$module_dir/pyproject.toml" 2>/dev/null || true)"
    if [[ -n "${py_line:-}" ]]; then
      pyver_req="$(printf '%s\n' "$py_line" | cut -d'=' -f2- | tr -d ' \"')"
    fi
    if [[ -z "${pyver_req:-}" ]]; then
      py_line="$(grep -m1 -E '^python[[:space:]]*=' "$module_dir/pyproject.toml" 2>/dev/null || true)"
      if [[ -n "${py_line:-}" ]]; then
        pyver_req="$(printf '%s\n' "$py_line" | cut -d'=' -f2- | tr -d ' \"')"
      fi
    fi
    if [[ -n "${pyver_req:-}" ]]; then
      runtime_version="python-$pyver_req"
      add_note "Python: version $pyver_req from pyproject.toml"
    fi
  fi

  (( has_marker == 1 )) || return 0

  if [[ -f "$module_dir/manage.py" ]]; then
    framework="django"
    add_note "Python: manage.py present -> Django"
  fi

  local has_asgi=0
  local has_wsgi=0

  if find "$module_dir" -maxdepth 5 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'asgi.py' -print -quit >/dev/null 2>&1; then
    has_asgi=1
    add_note "Python: asgi.py present"
  fi
  if find "$module_dir" -maxdepth 5 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'wsgi.py' -print -quit >/dev/null 2>&1; then
    has_wsgi=1
    add_note "Python: wsgi.py present"
  fi

  if find "$module_dir" -maxdepth 5 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name '*.py' -print -quit >/dev/null 2>&1; then
    if grep -R -i -m1 'fastapi' "$module_dir" --include='*.py' 2>/dev/null >/dev/null; then
      framework="fastapi"
      add_note "Python: code mentions fastapi"
    elif grep -R -i -m1 'flask' "$module_dir" --include='*.py' 2>/dev/null >/dev/null; then
      [[ "$framework" == "none" ]] && framework="flask"
      add_note "Python: code mentions flask"
    elif grep -R -i -m1 'django' "$module_dir" --include='*.py' 2>/dev/null >/dev/null; then
      framework="django"
      add_note "Python: code mentions django"
    fi
  fi

  if [[ "$framework" == "none" ]]; then
    if (( has_asgi == 1 && has_wsgi == 1 )); then
      framework="asgi-wsgi-generic"
    elif (( has_asgi == 1 )); then
      framework="asgi-generic"
    elif (( has_wsgi == 1 )); then
      framework="wsgi-generic"
    fi
  fi

  local score=60
  if [[ "$framework" != "none" ]]; then
    score=$((score+15))
    add_note "Python: framework=$framework"
  fi
  if [[ "$build_tool" != "pip" ]]; then
    score=$((score+5))
  fi

  # Build/test commands
  local build_cmd=""
  local test_cmd="pytest"
  if [[ "$build_tool" == "poetry" ]]; then
    build_cmd="poetry build"
    test_cmd="poetry run pytest"
  elif [[ -f "$module_dir/setup.py" || -f "$module_dir/pyproject.toml" ]]; then
    build_cmd="python -m build"
  fi
  add_build_cmd_candidate "$build_cmd" "$score"
  add_test_cmd_candidate "$test_cmd" "$score"
  add_runtime_candidate "$runtime_version" "$score"

  local prev_score="$BEST_SCORE"
  consider_candidate "python" "$framework" "$build_tool" "$test_tool" "$artifact_type" "$score" "Python module"
  if (( BEST_SCORE > prev_score )); then
    RUNTIME_VERSION="$runtime_version"
  fi
}

# Java / Kotlin
detect_java_kotlin() {
  local module_dir="$1"

  local has_marker=0
  local build_tool="unknown"
  local framework="java-generic"
  local language="java"
  local test_tool="junit"
  local artifact_type="jar"
  local runtime_version="unknown"
  local score=60

  if [[ -f "$module_dir/pom.xml" ]]; then
    has_marker=1
    build_tool="maven"
    add_note "Java: pom.xml present"
    local jv
    jv="$(extract_maven_java_version "$module_dir/pom.xml")"
    if [[ -n "${jv:-}" ]]; then
      if is_numeric_version "$jv"; then
        runtime_version="java-$jv"
        add_note "Java: version $jv from pom.xml"
        add_runtime_candidate "$runtime_version" "$score"
      fi
    fi
    if grep -qi 'spring-boot' "$module_dir/pom.xml" 2>/dev/null; then
      framework="spring-boot"
    fi
    add_build_cmd_candidate "mvn -B package" "$score"
    add_test_cmd_candidate "mvn -B test" "$score"
  fi

  if [[ -f "$module_dir/build.gradle" || -f "$module_dir/build.gradle.kts" ]]; then
    has_marker=1
    build_tool="gradle"
    add_note "Java: build.gradle present"
    local gf="$module_dir/build.gradle"
    [[ -f "$module_dir/build.gradle.kts" ]] && gf="$module_dir/build.gradle.kts"
    if [[ "$runtime_version" == "unknown" ]]; then
      local gv
      gv="$(grep -m1 -E 'JavaVersion\\.VERSION_' "$gf" 2>/dev/null || true)"
      if [[ "$gv" =~ JavaVersion\.VERSION_([0-9]+) ]]; then
        runtime_version="java-${BASH_REMATCH[1]}"
        add_note "Java: version ${BASH_REMATCH[1]} from Gradle JavaVersion"
        add_runtime_candidate "$runtime_version" "$score"
      else
        gv="$(extract_gradle_toolchain_version "$gf")"
        [[ -z "${gv:-}" ]] && gv="$(extract_gradle_compat_version "$gf")"
        if [[ -n "${gv:-}" ]]; then
          if is_numeric_version "$gv"; then
            runtime_version="java-$gv"
            add_note "Java: version $gv from Gradle toolchain/compatibility"
            add_runtime_candidate "$runtime_version" "$score"
          fi
        fi
      fi
    fi
    if grep -qi 'spring-boot' "$gf" 2>/dev/null; then
      framework="spring-boot"
    fi
    if grep -qi 'kotlin' "$gf" 2>/dev/null; then
      language="kotlin"
      add_note "Kotlin: kotlin in Gradle file"
    fi
    local gradle_cmd="./gradlew"
    [[ ! -x "$module_dir/gradlew" ]] && gradle_cmd="gradle"
    add_build_cmd_candidate "$gradle_cmd build" "$score"
    add_test_cmd_candidate "$gradle_cmd test" "$score"
  fi

  if [[ "$runtime_version" == "unknown" ]]; then
    local gpv
    gpv="$(extract_gradle_properties_java_version "$module_dir")"
    if [[ -n "${gpv:-}" ]]; then
      if is_numeric_version "$gpv"; then
        runtime_version="java-$gpv"
        add_note "Java: version $gpv from gradle.properties"
        add_runtime_candidate "$runtime_version" "$score"
      fi
    fi
    if [[ "$runtime_version" == "unknown" ]]; then
      local gfilev
      gfilev="$(extract_gradle_java_version_upwards "$module_dir")"
      if [[ -n "${gfilev:-}" ]]; then
        if is_numeric_version "$gfilev"; then
          runtime_version="java-$gfilev"
          add_note "Java: version $gfilev from Gradle files"
          add_runtime_candidate "$runtime_version" "$score"
        fi
      fi
    fi
    if [[ "$runtime_version" == "unknown" ]]; then
      local ggrepv
      ggrepv="$(extract_java_version_grep_repo "$module_dir")"
      if [[ -n "${ggrepv:-}" ]]; then
        if is_numeric_version "$ggrepv"; then
          runtime_version="java-$ggrepv"
          add_note "Java: version $ggrepv from repo search"
          add_runtime_candidate "$runtime_version" "$score"
        fi
      fi
    fi
  fi

  if [[ -f "$module_dir/build.xml" ]]; then
    has_marker=1
    [[ "$build_tool" == "unknown" ]] && build_tool="ant"
    add_note "Java: build.xml present"
    if [[ "$runtime_version" == "unknown" ]]; then
      local av
      av="$(extract_ant_java_version "$module_dir/build.xml")"
      if [[ -n "${av:-}" ]]; then
        if is_numeric_version "$av"; then
          runtime_version="java-$av"
          add_note "Java: version $av from build.xml"
        fi
      fi
    fi
    add_runtime_candidate "$runtime_version" "$score"
    add_build_cmd_candidate "ant" "$score"
    add_test_cmd_candidate "ant test" "$score"
  fi

  (( has_marker == 1 )) || return 0

  if [[ -d "$module_dir/src/main/kotlin" ]]; then
    language="kotlin"
    add_note "Kotlin: src/main/kotlin present"
  fi
  if [[ -d "$module_dir/src/main/java" ]]; then
    add_note "Java: src/main/java present"
  fi
  if [[ -d "$module_dir/src/test/java" || -d "$module_dir/src/test/kotlin" ]]; then
    add_note "Java/Kotlin: src/test present"
  fi

  if [[ "$framework" != "spring-boot" ]]; then
    if find "$module_dir/src" -maxdepth 6 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( -name '*.java' -o -name '*.kt' \) -print -quit >/dev/null 2>&1; then
      if grep -R -m1 '@SpringBootApplication' "$module_dir/src" --include='*.java' --include='*.kt' 2>/dev/null >/dev/null; then
        framework="spring-boot"
        add_note "Java/Kotlin: @SpringBootApplication in code"
      fi
    fi
  fi

  if [[ "$framework" == "spring-boot" ]]; then
    score=$((score+20))
    add_note "Java/Kotlin: framework=spring-boot"
  fi
  if [[ "$build_tool" == "maven" || "$build_tool" == "gradle" ]]; then
    score=$((score+5))
  fi
  if [[ "$language" == "kotlin" ]]; then
    score=$((score+3))
  fi

  local prev_score="$BEST_SCORE"
  consider_candidate "$language" "$framework" "$build_tool" "$test_tool" "$artifact_type" "$score" "Java/Kotlin module"
  if (( BEST_SCORE > prev_score )); then
    RUNTIME_VERSION="$runtime_version"
  fi
}

#######################################
# Анализ одного модуля
#######################################

analyze_module() {
  local module_dir="$1"

  reset_detection_state

  detect_go "$module_dir"
  detect_ruby "$module_dir"
  detect_node "$module_dir"
  detect_python "$module_dir"
  detect_java_kotlin "$module_dir"

  record_module "$module_dir"
  aggregate_current_module_into_repo
}

#######################################
# Печать агрегированного JSON
#######################################

print_sorted_list_from_arrays() {
  local key="$1"
  local -n names_arr="$2"
  local -n scores_arr="$3"

  printf '  "%s": [' "$key"

  if ((${#names_arr[@]} == 0)); then
    printf '],\n'
    return
  fi

  local tmp
  tmp="$(mktemp)"
  local i
  for i in "${!names_arr[@]}"; do
    [[ -z "${names_arr[$i]}" ]] && continue
    printf '%s %s\n' "${scores_arr[$i]}" "${names_arr[$i]}" >>"$tmp"
  done

  local first=1
  while read -r score name; do
    [[ -z "$name" ]] && continue
    if ((first)); then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$(json_escape "$name")"
  done < <(sort -nr -k1,1 "$tmp")
  rm -f "$tmp"

  printf '],\n'
}

print_repo_json() {
  local root="$1"
  local dockerflag="$2"
  local dockerfiles_json="$3"
  local compose_json="$4"

  printf '{\n'
  printf '  "root_path": "%s",\n' "$(json_escape "$root")"
  printf '  "has_dockerfile": %s,\n' "$dockerflag"
  printf '  "dockerfiles": %s,\n' "$dockerfiles_json"
  printf '  "docker_compose_files": %s,\n' "$compose_json"

  print_sorted_list_from_arrays "languages" REPO_LANGS REPO_LANG_SCORES
  print_sorted_list_from_arrays "frameworks" REPO_FRAMEWORKS REPO_FRAMEWORK_SCORES
  print_sorted_list_from_arrays "build_tools" REPO_BUILD_TOOLS REPO_BUILD_TOOL_SCORES
  print_sorted_list_from_arrays "test_tools" REPO_TEST_TOOLS REPO_TEST_TOOL_SCORES
  print_sorted_list_from_arrays "artifact_types" REPO_ARTIFACT_TYPES REPO_ARTIFACT_TYPE_SCORES
  print_sorted_list_from_arrays "runtime_versions" REPO_RUNTIME_VERSIONS REPO_RUNTIME_VERSION_SCORES
  print_sorted_list_from_arrays "build_commands" REPO_BUILD_CMDS REPO_BUILD_CMD_SCORES
  print_sorted_list_from_arrays "test_commands" REPO_TEST_CMDS REPO_TEST_CMD_SCORES

  # notes – последним, без запятой
  printf '  "notes": ['
  local i
  for i in "${!REPO_NOTES[@]}"; do
    [[ $i -gt 0 ]] && printf ', '
    printf '"%s"' "$(json_escape "${REPO_NOTES[$i]}")"
  done
  printf ']\n'

  printf '}\n'
}

#######################################
# Основной workflow
#######################################

run_analyze() {
  local root=""
  local tmp_dir=""
  local dockerfiles_json="[]"
  local compose_json="[]"

  if [[ -n "$REPO_URL" ]]; then
    tmp_dir="$(mktemp -d "/tmp/selfdeploy_repo.XXXXXX")"
    git clone --depth 1 "$REPO_URL" "$tmp_dir" >/dev/null 2>&1
    root="$tmp_dir"
    if [[ "$KEEP_CLONE" -eq 0 ]]; then
      trap 'rm -rf "'"$tmp_dir"'" 2>/dev/null || true' EXIT
    fi
  else
    root="$LOCAL_PATH"
  fi

  if [[ ! -d "$root" ]]; then
    echo "Path does not exist or is not a directory: $root" >&2
    exit 1
  fi

  root="$(cd "$root" && pwd)"

  repo_reset
  discover_modules "$root"

  local idx
  for idx in "${!MODULE_DIRS[@]}"; do
    CURRENT_MODULE_REL="${MODULE_RELS[$idx]}"
    analyze_module "${MODULE_DIRS[$idx]}"
  done

  local dockerflag="false"
  if has_dockerfile "$root"; then
    dockerflag="true"
  fi
  dockerfiles_json="$(find "$root" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -iname 'dockerfile' -print 2>/dev/null | awk '{printf "\"%s\",", $0}' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')"
  compose_json="$(find "$root" -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f \( -iname 'docker-compose.yml' -o -iname 'docker-compose.yaml' -o -iname 'compose.yml' -o -iname 'compose.yaml' \) -print 2>/dev/null | awk '{printf "\"%s\",", $0}' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')"
  [[ -z "$dockerfiles_json" ]] && dockerfiles_json="[]"
  [[ -z "$compose_json" ]] && compose_json="[]"

  print_repo_json "$root" "$dockerflag" "$dockerfiles_json" "$compose_json"
}

#######################################
# Entry point
#######################################

parse_args "$@"
run_analyze

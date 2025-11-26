#!/usr/bin/env bash
# selfdeploy.sh
# Анализ репозитория/директории.
# Внутри смотрит по модулям (manifest-файлы), снаружи отдаёт один
# агрегированный JSON по всему репозиторию.

set -euo pipefail

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
BEST_SCORE=-1

declare -a NOTES=()

reset_detection_state() {
  LANGUAGE="unknown"
  FRAMEWORK="unknown"
  BUILD_TOOL="unknown"
  TEST_TOOL="unknown"
  ARTIFACT_TYPE="unknown"
  BEST_SCORE=-1
  NOTES=()
}

add_note() {
  local note="$1"
  local n
  for n in "${NOTES[@]}"; do
    [[ "$n" == "$note" ]] && return 0
  done
  NOTES+=("$note")
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
declare -a REPO_NOTES=()

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
  REPO_NOTES=()
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

  if find "$module_dir" -maxdepth 4 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name 'main.go' -print -quit >/dev/null 2>&1; then
    score=$((score+10))
    add_note "Go: main.go present"
  fi

  if find "$module_dir" -maxdepth 6 -type d \( $IGNORED_DIRS_EXPR \) -prune -o -type f -name '*_test.go' -print -quit >/dev/null 2>&1; then
    score=$((score+5))
    add_note "Go: *_test.go present"
  fi

  consider_candidate "go" "none" "go" "go test" "binary" "$score" "Go module"
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

  consider_candidate "$language" "$framework" "$build_tool" "jest" "node-app" "$score" "Node.js/TypeScript module"
}

# Python (c учётом ASGI/WSGI generic)
detect_python() {
  local module_dir="$1"

  local has_marker=0
  local framework="none"
  local build_tool="pip"
  local test_tool="pytest"
  local artifact_type="wheel"

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

  consider_candidate "python" "$framework" "$build_tool" "$test_tool" "$artifact_type" "$score" "Python module"
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

  if [[ -f "$module_dir/pom.xml" ]]; then
    has_marker=1
    build_tool="maven"
    add_note "Java: pom.xml present"
    if grep -qi 'spring-boot' "$module_dir/pom.xml" 2>/dev/null; then
      framework="spring-boot"
    fi
  fi

  if [[ -f "$module_dir/build.gradle" || -f "$module_dir/build.gradle.kts" ]]; then
    has_marker=1
    build_tool="gradle"
    add_note "Java: build.gradle present"
    local gf="$module_dir/build.gradle"
    [[ -f "$module_dir/build.gradle.kts" ]] && gf="$module_dir/build.gradle.kts"
    if grep -qi 'spring-boot' "$gf" 2>/dev/null; then
      framework="spring-boot"
    fi
    if grep -qi 'kotlin' "$gf" 2>/dev/null; then
      language="kotlin"
      add_note "Kotlin: kotlin in Gradle file"
    fi
  fi

  if [[ -f "$module_dir/build.xml" ]]; then
    has_marker=1
    [[ "$build_tool" == "unknown" ]] && build_tool="ant"
    add_note "Java: build.xml present"
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

  local score=60
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

  consider_candidate "$language" "$framework" "$build_tool" "$test_tool" "$artifact_type" "$score" "Java/Kotlin module"
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

  printf '{\n'
  printf '  "root_path": "%s",\n' "$(json_escape "$root")"
  printf '  "has_dockerfile": %s,\n' "$dockerflag"

  print_sorted_list_from_arrays "languages" REPO_LANGS REPO_LANG_SCORES
  print_sorted_list_from_arrays "frameworks" REPO_FRAMEWORKS REPO_FRAMEWORK_SCORES
  print_sorted_list_from_arrays "build_tools" REPO_BUILD_TOOLS REPO_BUILD_TOOL_SCORES
  print_sorted_list_from_arrays "test_tools" REPO_TEST_TOOLS REPO_TEST_TOOL_SCORES
  print_sorted_list_from_arrays "artifact_types" REPO_ARTIFACT_TYPES REPO_ARTIFACT_TYPE_SCORES

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
    analyze_module "${MODULE_DIRS[$idx]}"
  done

  local dockerflag="false"
  if has_dockerfile "$root"; then
    dockerflag="true"
  fi

  print_repo_json "$root" "$dockerflag"
}

#######################################
# Entry point
#######################################

parse_args "$@"
run_analyze

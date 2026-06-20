#!/usr/bin/env bash
# =============================================================================
# check-my-aws-permissions.sh
#
#   現在のAWS認証主体（`aws login --remote` / `aws sso login` / 環境変数 /
#   インスタンスプロファイル等で取得済みの資格情報）を使い、
#   「自分にどんな権限があるか」を読み取り専用で確認するツール。
#
#   重要: IAMには「付与された全権限を一括で完全取得する単一API」は存在しません。
#         本ツールは "代表的なアクションに対する実効権限の確認" を行うものであり、
#         全権限を網羅的に列挙するものではありません。
#
# 実行方式 (--mode):
#   simulate : iam:SimulatePrincipalPolicy でポリシー評価（実アクセスは発生しない）
#   live     : 実際の読み取り系APIを呼び出し、成否で許可/拒否を判定
#   auto     : simulate を試し、権限不足等で使えなければ live にフォールバック（既定）
#
# 安全性:
#   - 使用するのは「読み取り系API」と「IAMポリシーシミュレーションAPI」のみ。
#     リソースの作成・変更・削除は一切行いません。
#   - アクセスキー / シークレットキー / セッショントークンは絶対に表示しません。
#
# 使い方:
#   ./check-my-aws-permissions.sh
#   AWS_PROFILE=my-sso ./check-my-aws-permissions.sh
#   ./check-my-aws-permissions.sh --profile my-sso --region ap-northeast-1
#   ./check-my-aws-permissions.sh --mode live --s3-bucket my-bucket --s3-key path/to/obj
#   ./check-my-aws-permissions.sh --mode simulate
#   ./check-my-aws-permissions.sh -h
#
# 動作要件:
#   - bash 3.2 以上（macOS 標準 bash でも動作）
#   - AWS CLI v2（必須） / jq（任意・あれば参考JSONを整形表示）
#
# 終了コード:
#   0 : 正常終了（権限の有無に関わらず、確認処理が完了）
#   1 : 認証失敗・前提コマンド不足など、確認を続行できない致命的エラー
#   2 : 引数エラー
# =============================================================================

set -Eeuo pipefail

# --- グローバル状態（nounset 対策で必ず初期化）-------------------------------
AWS_OUT=""
AWS_ERR=""
ERR_TMP=""
RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""

# 認証主体に関する情報
ACCOUNT_ID=""
CALLER_ARN=""
USER_ID=""
PARTITION="aws"
PRINCIPAL_TYPE="unknown"
PRINCIPAL_NAME=""
SIM_SOURCE=""

# live_probe の結果受け渡し用
LP_DECISION="unknown"
LP_RESOURCE="*"
LP_NOTE=""

# オプション
MODE="auto"
REGION=""
REGION_OVERRIDE=""
S3_BUCKET=""
S3_KEY=""
CODECOMMIT_REPO=""
USE_COLOR="auto"
HAVE_JQ=0
RESOURCE_ARNS=()

# 確認対象の代表的アクション（最低限の必須セット）
ACTIONS=(
  "s3:ListAllMyBuckets"
  "s3:ListBucket"
  "s3:GetObject"
  "ec2:DescribeInstances"
  "ec2:DescribeRegions"
  "iam:GetUser"
  "iam:ListRoles"
  "iam:ListAttachedUserPolicies"
  "lambda:ListFunctions"
  "cloudwatch:DescribeAlarms"
  "logs:DescribeLogGroups"
  "codecommit:ListRepositories"
  "codecommit:GetRepository"
  "sts:GetCallerIdentity"
)

# =============================================================================
# トラップ / クリーンアップ
# =============================================================================
on_err() {
  local code=$? line="${1:-?}"
  # head/less へのパイプ等で発生する SIGPIPE(141) はエラー扱いしない
  if [[ "$code" -eq 141 ]]; then
    return 0
  fi
  printf '%s[ERROR]%s 予期しないエラーが発生しました (line: %s, exit: %s)\n' \
    "${RED}" "${RESET}" "$line" "$code" >&2
}

cleanup() {
  local code=$?
  # クリーンアップ中の ERR/EXIT 再発火を防ぐ
  trap - ERR EXIT
  if [[ -n "${ERR_TMP}" && -e "${ERR_TMP}" ]]; then
    rm -f "${ERR_TMP}"
  fi
  exit "$code"
}

trap 'on_err "$LINENO"' ERR
trap cleanup EXIT

# =============================================================================
# 出力ヘルパ
# =============================================================================
say()  { printf '%s\n' "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n'  "${YELLOW}" "${RESET}" "$*"; }
note() { printf '%s%s%s\n' "${DIM}" "$*" "${RESET}"; }

hr() {
  say "----------------------------------------------------------------------"
}

usage() {
  cat <<'USAGE'
check-my-aws-permissions.sh
  現在のAWS認証主体の「実効権限」を読み取り専用で確認するツール。

使い方:
  ./check-my-aws-permissions.sh [オプション]

オプション:
  --mode <auto|simulate|live>  確認方式 (既定: auto)
                                 simulate : iam:SimulatePrincipalPolicy で評価（実アクセスなし）
                                 live     : 実際の読み取りAPIを呼び出し成否で判定
                                 auto     : simulate を試し、権限不足なら live にフォールバック
  --region <region>            リージョン依存APIで使用するリージョン
  --profile <name>             使用するAWSプロファイル（AWS_PROFILE を設定）
  --s3-bucket <name>           s3:ListBucket / s3:GetObject の確認対象バケット名
  --s3-key <key>               s3:GetObject の確認対象オブジェクトキー
  --codecommit-repo <name>     codecommit:GetRepository の確認対象リポジトリ名
  --resource-arn <arn>         シミュレーション対象リソースARN（複数指定可・既定は *)
  --no-color | --color         色出力の無効化 / 強制
  -h | --help                  このヘルプを表示

実行例:
  ./check-my-aws-permissions.sh
  AWS_PROFILE=my-sso ./check-my-aws-permissions.sh
  ./check-my-aws-permissions.sh --profile my-sso --region ap-northeast-1
  ./check-my-aws-permissions.sh --mode live --s3-bucket my-bucket --s3-key path/to/obj
  ./check-my-aws-permissions.sh --mode live --codecommit-repo my-repo

注意:
  - IAMには「付与された全権限を1回で完全取得する単一API」は存在しません。
    本ツールは代表的アクションに対する実効権限の確認であり、全権限の網羅ではありません。
  - アクセスキー / シークレットキー等の認証情報は一切表示しません。
USAGE
}

# =============================================================================
# 色設定
# =============================================================================
setup_color() {
  local enable="no"
  case "$USE_COLOR" in
    yes) enable="yes" ;;
    no)  enable="no" ;;
    auto)
      if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        enable="yes"
      fi
      ;;
  esac
  if [[ "$enable" == "yes" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
  else
    RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
  fi
}

# =============================================================================
# 前提チェック
# =============================================================================
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $1"
    return 1
  fi
  return 0
}

# =============================================================================
# AWS呼び出しラッパ
#   - 標準出力を AWS_OUT、標準エラーを AWS_ERR に格納し、終了コードを返す。
#   - set -e を踏まないよう、呼び出し側は必ず `if ...` か `... || rc=$?` で受ける。
# =============================================================================
aws_try() {
  local rc=0
  AWS_OUT=""
  AWS_OUT="$(aws "$@" 2>"$ERR_TMP")" || rc=$?
  AWS_ERR="$(<"$ERR_TMP")"
  : >"$ERR_TMP"
  return "$rc"
}

# 直近の AWS_ERR が「権限不足」を示すか判定
is_access_denied() {
  case "$AWS_ERR" in
    *AccessDenied*|*"not authorized to perform"*|*UnauthorizedOperation*|*AuthorizationError*|*"explicit deny"*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# AWS_ERR の先頭行を指定文字数で取り出す（パイプを使わず SIGPIPE を回避）
first_err_line() {
  local n="${1:-120}" first
  first="${AWS_ERR%%$'\n'*}"
  printf '%s' "${first:0:$n}"
}

# =============================================================================
# ARN ユーティリティ
# =============================================================================
arn_partition() {
  local arn="$1"
  arn="${arn#arn:}"
  printf '%s' "${arn%%:*}"
}

# =============================================================================
# 認証情報の取得と主体タイプの判定
# =============================================================================
resolve_identity() {
  if ! aws_try sts get-caller-identity \
        --query '[Account,Arn,UserId]' --output text; then
    err "AWS認証に失敗しました。資格情報が無効か、未ログインの可能性があります。"
    err "例: aws login --remote / aws sso login --profile <name> などで認証してください。"
    err "詳細: $(first_err_line 200)"
    exit 1
  fi

  IFS=$'\t' read -r ACCOUNT_ID CALLER_ARN USER_ID <<<"$AWS_OUT" || true

  if [[ -z "$ACCOUNT_ID" || -z "$CALLER_ARN" ]]; then
    err "get-caller-identity の結果を解析できませんでした。"
    exit 1
  fi

  PARTITION="$(arn_partition "$CALLER_ARN")"

  case "$CALLER_ARN" in
    *":root")
      PRINCIPAL_TYPE="account_root"
      PRINCIPAL_NAME="root"
      SIM_SOURCE=""
      ;;
    *":user/"*)
      PRINCIPAL_TYPE="iam_user"
      PRINCIPAL_NAME="${CALLER_ARN##*/}"
      SIM_SOURCE="$CALLER_ARN"
      ;;
    *":assumed-role/"*)
      local rest role
      rest="${CALLER_ARN#*:assumed-role/}"   # RoleName/SessionName
      role="${rest%%/*}"                      # RoleName
      PRINCIPAL_NAME="$role"
      case "$role" in
        AWSReservedSSO_*) PRINCIPAL_TYPE="sso_role" ;;
        *)                PRINCIPAL_TYPE="assumed_role" ;;
      esac
      # ロールARN（naive）。ロールにパスがある場合に備え、可能なら get-role で正確化。
      SIM_SOURCE="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${role}"
      if aws_try iam get-role --role-name "$role" \
            --query 'Role.Arn' --output text; then
        if [[ -n "$AWS_OUT" && "$AWS_OUT" != "None" ]]; then
          SIM_SOURCE="$AWS_OUT"
        fi
      fi
      ;;
    *":federated-user/"*)
      PRINCIPAL_TYPE="federated_user"
      PRINCIPAL_NAME="${CALLER_ARN##*/}"
      SIM_SOURCE=""
      ;;
    *)
      PRINCIPAL_TYPE="unknown"
      PRINCIPAL_NAME=""
      SIM_SOURCE=""
      ;;
  esac
}

principal_type_label() {
  case "$PRINCIPAL_TYPE" in
    account_root)   printf 'account_root (アカウントのルートユーザー)' ;;
    iam_user)       printf 'iam_user (IAMユーザー)' ;;
    assumed_role)   printf 'assumed_role (STSで引き受けたIAMロール)' ;;
    sso_role)       printf 'sso_role (IAM Identity Center / SSO 由来のロール)' ;;
    federated_user) printf 'federated_user (フェデレーテッドユーザー)' ;;
    *)              printf 'unknown (判定不能)' ;;
  esac
}

# =============================================================================
# 主体に紐づく IAM 情報の取得（ベストエフォート / 権限不足は許容）
# =============================================================================
print_name_list() {
  local label="$1" data="$2"
  if [[ -z "$data" || "$data" == "None" ]]; then
    say "    ${label}: (なし、または取得結果が空)"
    return 0
  fi
  say "    ${label}:"
  local -a items=()
  read -r -a items <<<"$data"
  local item
  for item in "${items[@]}"; do
    say "      - ${item}"
  done
}

gather_iam_info() {
  case "$PRINCIPAL_TYPE" in
    iam_user)
      say "    IAMユーザー名: ${PRINCIPAL_NAME}"
      if aws_try iam list-attached-user-policies --user-name "$PRINCIPAL_NAME" \
            --query 'AttachedPolicies[].PolicyName' --output text; then
        print_name_list "アタッチ済み管理ポリシー" "$AWS_OUT"
      else
        say "    アタッチ済み管理ポリシー: 取得不可（$(first_err_line 60)）"
      fi
      if aws_try iam list-user-policies --user-name "$PRINCIPAL_NAME" \
            --query 'PolicyNames' --output text; then
        print_name_list "インラインポリシー" "$AWS_OUT"
      fi
      if aws_try iam list-groups-for-user --user-name "$PRINCIPAL_NAME" \
            --query 'Groups[].GroupName' --output text; then
        print_name_list "所属グループ" "$AWS_OUT"
      fi
      ;;
    assumed_role|sso_role)
      say "    ロール名: ${PRINCIPAL_NAME}"
      if aws_try iam list-attached-role-policies --role-name "$PRINCIPAL_NAME" \
            --query 'AttachedPolicies[].PolicyName' --output text; then
        print_name_list "アタッチ済み管理ポリシー" "$AWS_OUT"
      else
        say "    アタッチ済み管理ポリシー: 取得不可（$(first_err_line 60)）"
      fi
      if aws_try iam list-role-policies --role-name "$PRINCIPAL_NAME" \
            --query 'PolicyNames' --output text; then
        print_name_list "インラインポリシー" "$AWS_OUT"
      fi
      ;;
    account_root)
      say "    アカウントのルートユーザーです。ルートは全権限を保持するため、"
      say "    本ツールでのIAM詳細取得・権限確認は限定的です。"
      ;;
    *)
      say "    この主体タイプ（${PRINCIPAL_TYPE}）では、紐づくIAM詳細情報の取得は限定的です。"
      ;;
  esac
}

# =============================================================================
# 結果テーブル描画
# =============================================================================
colorize_decision() {
  local d="$1" c
  case "$d" in
    allowed)             c="$GREEN" ;;
    explicitDeny|denied) c="$RED" ;;
    implicitDeny)        c="$YELLOW" ;;
    *)                   c="$DIM" ;;
  esac
  printf '%s%s%s' "$c" "$d" "$RESET"
}

print_table_header() {
  printf '%-30s %-13s %-26s %s\n' "ACTION" "DECISION" "RESOURCE" "NOTE"
  printf '%-30s %-13s %-26s %s\n' \
    "------------------------------" "-------------" "--------------------------" "----"
}

# 注: NOTE を最終列に置くことで、日本語（マルチバイト）による桁ずれを回避している。
print_row() {
  local action="$1" decision="$2" resource="$3" rnote="${4:-}"
  local dec_colored pad width=13 dlen
  dlen=${#decision}
  dec_colored="$(colorize_decision "$decision")"
  pad=""
  if [[ "$dlen" -lt "$width" ]]; then
    pad="$(printf '%*s' "$((width - dlen))" '')"
  fi
  printf '%-30s %s%s %-26s %s\n' "$action" "$dec_colored" "$pad" "$resource" "$rnote"
}

note_for_action() {
  case "$1" in
    s3:ListBucket|s3:GetObject)
      printf '%s' "リソースレベル。*評価のため特定バケット限定許可は implicitDeny になり得る" ;;
    iam:ListAttachedUserPolicies)
      printf '%s' "IAMユーザー向け。ロール/SSO主体では非該当の場合あり" ;;
    *)
      printf '' ;;
  esac
}

# =============================================================================
# 方式1: ポリシーシミュレーション
#   戻り値 0 = 結果を表示できた / 1 = 実行不可（呼び出し側でフォールバック判断）
# =============================================================================
run_simulation() {
  if [[ -z "$SIM_SOURCE" ]]; then
    warn "シミュレーション対象の主体ARNを特定できないため、ポリシーシミュレーションは実行できません（主体タイプ: ${PRINCIPAL_TYPE}）。"
    return 1
  fi

  local -a cmd=(iam simulate-principal-policy
                --policy-source-arn "$SIM_SOURCE"
                --action-names "${ACTIONS[@]}"
                --query 'EvaluationResults[].[EvalActionName,EvalDecision,EvalResourceName]'
                --output text)
  if [[ ${#RESOURCE_ARNS[@]} -gt 0 ]]; then
    cmd+=(--resource-arns "${RESOURCE_ARNS[@]}")
  fi

  local rc=0
  aws_try "${cmd[@]}" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    if is_access_denied; then
      warn "iam:SimulatePrincipalPolicy の権限がないため、シミュレーション権限がないため確認不可。"
    else
      warn "ポリシーシミュレーションの呼び出しに失敗しました: $(first_err_line 120)"
    fi
    return 1
  fi

  say "  確認方式: simulate（iam:SimulatePrincipalPolicy によるポリシー評価。実アクセスは発生しません）"
  hr
  print_table_header

  local action decision resource rmapped rnote
  while IFS=$'\t' read -r action decision resource; do
    if [[ -z "$action" ]]; then
      continue
    fi
    if [[ -z "$resource" || "$resource" == "None" ]]; then
      rmapped='*'
    else
      rmapped="$resource"
    fi
    rnote="$(note_for_action "$action")"
    print_row "$action" "$decision" "$rmapped" "$rnote"
  done <<<"$AWS_OUT"

  return 0
}

# =============================================================================
# 方式2: ライブ（実際の読み取りAPIを呼び出して成否で判定）
#   ※ 呼び出すのは全て読み取り系API。作成・変更・削除は一切行わない。
# =============================================================================
live_probe() {
  local action="$1" rc=0
  local -a cmd=()
  LP_RESOURCE='*'
  LP_NOTE='実APIコール結果'

  case "$action" in
    s3:ListAllMyBuckets)
      cmd=(s3api list-buckets --output json) ;;
    iam:ListRoles)
      cmd=(iam list-roles --max-items 1 --output json) ;;
    sts:GetCallerIdentity)
      cmd=(sts get-caller-identity --output json) ;;
    ec2:DescribeRegions)
      cmd=(ec2 describe-regions --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    ec2:DescribeInstances)
      cmd=(ec2 describe-instances --max-items 1 --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    lambda:ListFunctions)
      cmd=(lambda list-functions --max-items 1 --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    cloudwatch:DescribeAlarms)
      cmd=(cloudwatch describe-alarms --max-records 1 --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    logs:DescribeLogGroups)
      cmd=(logs describe-log-groups --limit 1 --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    codecommit:ListRepositories)
      cmd=(codecommit list-repositories --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    codecommit:GetRepository)
      if [[ -z "$CODECOMMIT_REPO" ]]; then
        LP_DECISION='skipped'; LP_NOTE='--codecommit-repo 未指定のためライブ確認不可'; return 0
      fi
      if [[ -n "$REGION" && -n "$ACCOUNT_ID" ]]; then
        LP_RESOURCE="arn:${PARTITION}:codecommit:${REGION}:${ACCOUNT_ID}:${CODECOMMIT_REPO}"
      else
        LP_RESOURCE="$CODECOMMIT_REPO"
      fi
      cmd=(codecommit get-repository --repository-name "$CODECOMMIT_REPO" --output json)
      if [[ -n "$REGION" ]]; then cmd+=(--region "$REGION"); fi ;;
    iam:GetUser)
      if [[ "$PRINCIPAL_TYPE" != "iam_user" ]]; then
        LP_DECISION='skipped'; LP_NOTE='IAMユーザー以外は get-user 非対応のためスキップ'; return 0
      fi
      cmd=(iam get-user --output json) ;;
    iam:ListAttachedUserPolicies)
      if [[ "$PRINCIPAL_TYPE" != "iam_user" || -z "$PRINCIPAL_NAME" ]]; then
        LP_DECISION='skipped'; LP_NOTE='IAMユーザー以外は非該当のためスキップ'; return 0
      fi
      cmd=(iam list-attached-user-policies --user-name "$PRINCIPAL_NAME" --output json) ;;
    s3:ListBucket)
      if [[ -z "$S3_BUCKET" ]]; then
        LP_DECISION='skipped'; LP_NOTE='--s3-bucket 未指定のためライブ確認不可'; return 0
      fi
      LP_RESOURCE="arn:${PARTITION}:s3:::${S3_BUCKET}"
      cmd=(s3api list-objects-v2 --bucket "$S3_BUCKET" --max-items 1 --output json) ;;
    s3:GetObject)
      if [[ -z "$S3_BUCKET" || -z "$S3_KEY" ]]; then
        LP_DECISION='skipped'; LP_NOTE='--s3-bucket / --s3-key 未指定のためライブ確認不可'; return 0
      fi
      LP_RESOURCE="arn:${PARTITION}:s3:::${S3_BUCKET}/${S3_KEY}"
      # HeadObject は s3:GetObject 権限で評価される読み取り専用呼び出し
      cmd=(s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --output json) ;;
    *)
      LP_DECISION='unknown'; LP_NOTE='ライブ確認の定義なし'; return 0 ;;
  esac

  aws_try "${cmd[@]}" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    LP_DECISION='allowed'
  elif is_access_denied; then
    LP_DECISION='denied'
    LP_NOTE='実APIコールが権限不足で拒否された'
  else
    LP_DECISION='unknown'
    LP_NOTE="呼出エラー: $(first_err_line 45)"
  fi
  return 0
}

run_live() {
  say "  確認方式: live（実際の読み取りAPIを呼び出し、成否で判定。作成・変更・削除は行いません）"
  hr
  print_table_header
  local action
  for action in "${ACTIONS[@]}"; do
    LP_DECISION='unknown'
    LP_RESOURCE='*'
    LP_NOTE=''
    live_probe "$action"
    print_row "$action" "$LP_DECISION" "$LP_RESOURCE" "$LP_NOTE"
  done
}

print_legend() {
  hr
  say "凡例:"
  say "  allowed      : 許可（ポリシー上、実行可能）"
  say "  explicitDeny : 明示的な拒否（Deny ステートメントにより禁止）"
  say "  implicitDeny : 暗黙の拒否（許可が無いため不可）"
  say "  denied       : 実APIコールが権限不足で失敗（live方式）"
  say "  skipped      : 対象未指定・主体タイプ非該当などで確認をスキップ（live方式）"
  say "  unknown      : 判定不能（呼び出しエラー等）"
  say ""
  note "  ※ IAMには「付与された全権限を1回で完全取得する単一API」は存在しません。"
  note "     本結果は列挙した代表アクションに対する実効権限であり、全権限の網羅ではありません。"
  note "  ※ リソースを * （全リソース）で評価しているアクションは、特定リソースに限定して"
  note "     許可されている場合 implicitDeny と表示されることがあります（--s3-bucket / --resource-arn で限定可能）。"
  note "  ※ simulate はアイデンティティベースのポリシー評価であり、セッションポリシー / SCP /"
  note "     リソースベースポリシーの影響は完全には反映されません。最終的な実アクセスは live 方式で確認してください。"
}

# =============================================================================
# 引数解析
# =============================================================================
require_value() {
  # $1: オプション名, $2: 残り引数の個数
  if [[ "$2" -lt 2 ]]; then
    err "$1 には値が必要です。"
    usage
    exit 2
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --mode)         require_value "$1" "$#"; MODE="$2"; shift 2 ;;
      --mode=*)       MODE="${1#*=}"; shift ;;
      --region)       require_value "$1" "$#"; REGION_OVERRIDE="$2"; shift 2 ;;
      --region=*)     REGION_OVERRIDE="${1#*=}"; shift ;;
      --profile)      require_value "$1" "$#"; export AWS_PROFILE="$2"; shift 2 ;;
      --profile=*)    export AWS_PROFILE="${1#*=}"; shift ;;
      --s3-bucket)    require_value "$1" "$#"; S3_BUCKET="$2"; shift 2 ;;
      --s3-bucket=*)  S3_BUCKET="${1#*=}"; shift ;;
      --s3-key)       require_value "$1" "$#"; S3_KEY="$2"; shift 2 ;;
      --s3-key=*)     S3_KEY="${1#*=}"; shift ;;
      --codecommit-repo)   require_value "$1" "$#"; CODECOMMIT_REPO="$2"; shift 2 ;;
      --codecommit-repo=*) CODECOMMIT_REPO="${1#*=}"; shift ;;
      --resource-arn) require_value "$1" "$#"; RESOURCE_ARNS+=("$2"); shift 2 ;;
      --no-color)     USE_COLOR="no"; shift ;;
      --color)        USE_COLOR="yes"; shift ;;
      --)             shift; break ;;
      -*)             err "不明なオプション: $1"; usage; exit 2 ;;
      *)              err "不正な引数: $1"; usage; exit 2 ;;
    esac
  done

  case "$MODE" in
    auto|simulate|live) : ;;
    *) err "--mode は auto / simulate / live のいずれかです（指定値: ${MODE}）。"; exit 2 ;;
  esac
}

# REGION を --region > AWS_REGION > AWS_DEFAULT_REGION > aws configure get region の順で解決
resolve_region() {
  if [[ -n "$REGION_OVERRIDE" ]]; then
    REGION="$REGION_OVERRIDE"
  elif [[ -n "${AWS_REGION:-}" ]]; then
    REGION="$AWS_REGION"
  elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    REGION="$AWS_DEFAULT_REGION"
  else
    REGION="$(aws configure get region 2>/dev/null || true)"
  fi
}

# =============================================================================
# メイン
# =============================================================================
main() {
  parse_args "$@"
  setup_color

  require_cmd aws || exit 1
  if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
  fi

  ERR_TMP="$(mktemp "${TMPDIR:-/tmp}/awsperm.XXXXXX")"

  resolve_region

  say "======================================================================"
  say " AWS 実効権限チェック  (check-my-aws-permissions.sh)"
  say "======================================================================"
  say ""

  # --- [1] 認証情報 -----------------------------------------------------------
  say "[1] 認証情報 (aws sts get-caller-identity)"
  resolve_identity
  say "    アカウントID : ${ACCOUNT_ID}"
  say "    ARN          : ${CALLER_ARN}"
  say "    UserId       : ${USER_ID}"
  say "    パーティション: ${PARTITION}"
  say "    主体タイプ   : $(principal_type_label)"
  if [[ -n "${REGION}" ]]; then
    say "    リージョン   : ${REGION}（リージョン依存APIで使用）"
  else
    say "    リージョン   : (未設定。リージョン依存のlive確認は失敗する場合があります)"
  fi
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    if aws_try sts get-caller-identity --output json; then
      if [[ -n "$AWS_OUT" ]]; then
        note "    （参考・生JSON）"
        printf '%s\n' "$AWS_OUT" | jq . | sed 's/^/    /'
      fi
    fi
  fi
  say ""

  # --- [2] 主体に紐づくIAM情報 -----------------------------------------------
  say "[2] 主体に紐づくIAM情報（ベストエフォート・権限不足時はスキップ）"
  gather_iam_info
  say ""

  # --- [3] 代表的アクションの実効権限 ----------------------------------------
  say "[3] 代表的アクションに対する実効権限の確認"
  case "$MODE" in
    simulate)
      if ! run_simulation; then
        note "  （--mode simulate のため、live へのフォールバックは行いません）"
      fi
      ;;
    live)
      run_live
      ;;
    auto)
      if ! run_simulation; then
        say ""
        note "  → ポリシーシミュレーションが利用できないため、実APIコール（live）にフォールバックします。"
        say ""
        run_live
      fi
      ;;
  esac

  print_legend
  say ""
  note "完了しました。認証情報（アクセスキー等）は一切表示していません。"
}

main "$@"

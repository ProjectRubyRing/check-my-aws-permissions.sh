# check-my-aws-permissions.sh

現在のAWS認証主体（`aws login --remote` / `aws sso login` / 環境変数 / インスタンスプロファイル等で取得済みの資格情報）を使って、**「自分にどんな権限があるか」を読み取り専用で確認する** Bash ツールです。Linux / macOS で動作し、依存は AWS CLI v2 のみ（`jq` は任意）。

> **重要 — 前提として知っておくべきこと**
> IAM には「付与された全権限を1回で完全取得する単一API」は **存在しません**。本ツールは列挙した *代表的なアクション* に対する **実効権限（effective permission）の確認** を行うものであり、保有する全権限を網羅的に列挙するものではありません。

---

## 目次

- [特長](#特長)
- [動作要件](#動作要件)
- [配置と実行](#配置と実行)
- [使い方](#使い方)
- [オプション一覧](#オプション一覧)
- [確認方式（--mode）](#確認方式--mode)
- [出力例](#出力例)
- [判定（DECISION）の意味](#判定decisionの意味)
- [確認できること / できないこと](#確認できること--できないこと)
- [このツールが使用するAPIと必要なIAM権限](#このツールが使用するapiと必要なiam権限)
- [セキュリティ](#セキュリティ)
- [終了コード](#終了コード)
- [トラブルシューティング](#トラブルシューティング)
- [設計メモ・既知の制約](#設計メモ既知の制約)
- [ライセンス](#ライセンス)

---

## 特長

- **読み取り専用** — 使用するのは読み取り系 API と IAM ポリシーシミュレーション API のみ。リソースの作成・変更・削除は一切行いません。
- **資格情報を表示しない** — アクセスキー / シークレットキー / セッショントークンを画面に出力しません。
- **主体タイプを自動判定** — IAM ユーザー / AssumedRole / IAM Identity Center（SSO）由来ロール（`AWSReservedSSO_*`）/ ルート / フェデレーテッドユーザーを `sts get-caller-identity` の ARN から識別します。
- **3つの確認方式** — ポリシー評価（`simulate`）と実 API 呼び出し（`live`）、およびその自動フォールバック（`auto`）。
- **権限不足でも止まらない** — シミュレーション権限が無い場合もエラー終了せず、`シミュレーション権限がないため確認不可` と表示して処理を継続します。
- **可搬性** — bash 3.2（macOS 標準）でも動作。連想配列・`mapfile` 等の新しい機能に依存しません。`shellcheck` 指摘ゼロ。
- **日本語表示** — メッセージ・凡例・注意書きはすべて日本語。

---

## 動作要件

| 項目 | 要件 |
| --- | --- |
| シェル | bash 3.2 以上（Linux の bash 5 系 / macOS 標準 bash で動作確認） |
| AWS CLI | **v2 必須** |
| jq | 任意。あれば `get-caller-identity` の生 JSON を整形表示します |
| 認証 | 事前に何らかの方法で資格情報が有効化されていること（`aws login --remote`、`aws sso login`、環境変数、インスタンスプロファイル等） |

`aws login --remote` は AWS CLI v2（v2.32.0 以降）のコマンドで、ブラウザのコールバックを使わずヘッドレス / SSH 環境でコンソールセッション資格情報を取得できます。本ツールは資格情報の取得方法には依存せず、有効な認証状態であればそのまま利用します。

---

## 配置と実行

```bash
chmod +x check-my-aws-permissions.sh
./check-my-aws-permissions.sh
```

> **SSM Session Manager（ブラウザ端末）での注意**
> ブラウザ越しのターミナルは長いテキストの貼り付けで欠落・文字化けが起きることがあります。スクリプトはコピー＆ペーストではなく **ファイルとして転送** してから実行してください。

---

## 使い方

```bash
# 既存の認証情報をそのまま使用
./check-my-aws-permissions.sh

# プロファイルを指定（環境変数指定でも可）
AWS_PROFILE=my-sso ./check-my-aws-permissions.sh
./check-my-aws-permissions.sh --profile my-sso --region ap-northeast-1

# ポリシーシミュレーションのみ（実アクセスを一切発生させない）
./check-my-aws-permissions.sh --mode simulate

# 実 API 呼び出しで確認（S3 はバケット / オブジェクトを指定するとリソース単位で確認）
./check-my-aws-permissions.sh --mode live --s3-bucket my-bucket --s3-key path/to/obj

# CodeCommit のリポジトリを指定してリソース単位で確認
./check-my-aws-permissions.sh --mode live --codecommit-repo my-repo

# 特定リソース ARN に対してシミュレーション
./check-my-aws-permissions.sh --mode simulate --resource-arn arn:aws:s3:::my-bucket
```

---

## オプション一覧

| オプション | 説明 | 既定値 |
| --- | --- | --- |
| `--mode <auto\|simulate\|live>` | 確認方式 | `auto` |
| `--region <region>` | リージョン依存 API で使用するリージョン | 環境変数 / プロファイル設定に従う |
| `--profile <name>` | 使用する AWS プロファイル（`AWS_PROFILE` を設定） | なし |
| `--s3-bucket <name>` | `s3:ListBucket` / `s3:GetObject` の確認対象バケット | なし |
| `--s3-key <key>` | `s3:GetObject` の確認対象オブジェクトキー | なし |
| `--codecommit-repo <name>` | `codecommit:GetRepository` の確認対象リポジトリ名 | なし |
| `--resource-arn <arn>` | シミュレーション対象リソース ARN（複数指定可） | `*` |
| `--no-color` / `--color` | 色出力の無効化 / 強制 | 自動（TTY かつ `NO_COLOR` 未設定で有効） |
| `-h` / `--help` | ヘルプを表示 | — |

リージョンの解決順は `--region` > `AWS_REGION` > `AWS_DEFAULT_REGION` > `aws configure get region` です。

---

## 確認方式（--mode）

| モード | 動作 | 実アクセス |
| --- | --- | --- |
| `simulate` | `iam:SimulatePrincipalPolicy` でアイデンティティベースのポリシーを評価 | **発生しない** |
| `live` | 実際の読み取り系 API を呼び出し、成否で許可/拒否を判定 | 発生する（読み取りのみ） |
| `auto`（既定） | まず `simulate` を試し、権限不足等で使えなければ `live` に自動フォールバック | 状況による |

`simulate` はアクセスを発生させずに評価できる反面、セッションポリシー / SCP / リソースベースポリシーの影響を完全には反映しません。最終的な実アクセス可否を厳密に確認したい場合は `live` を使用してください。

---

## 出力例

### simulate が成功した場合（AssumedRole 主体）

```
[1] 認証情報 (aws sts get-caller-identity)
    アカウントID : 123456789012
    ARN          : arn:aws:sts::123456789012:assumed-role/AppOpsRole/taka-session
    UserId       : AROAEXAMPLEEXAMPLE:taka-session
    パーティション: aws
    主体タイプ   : assumed_role (STSで引き受けたIAMロール)
    リージョン   : ap-northeast-1（リージョン依存APIで使用）

[3] 代表的アクションに対する実効権限の確認
  確認方式: simulate（iam:SimulatePrincipalPolicy によるポリシー評価。実アクセスは発生しません）
----------------------------------------------------------------------
ACTION                         DECISION      RESOURCE                   NOTE
------------------------------ ------------- -------------------------- ----
s3:ListAllMyBuckets            allowed       *
s3:ListBucket                  implicitDeny  *                          リソースレベル。*評価のため特定バケット限定許可は implicitDeny になり得る
ec2:DescribeInstances          allowed       *
iam:GetUser                    explicitDeny  *
lambda:ListFunctions           allowed       *
...
```

### simulate 権限が無く live にフォールバックした場合

```
[3] 代表的アクションに対する実効権限の確認
[WARN] iam:SimulatePrincipalPolicy の権限がないため、シミュレーション権限がないため確認不可。

  → ポリシーシミュレーションが利用できないため、実APIコール（live）にフォールバックします。

  確認方式: live（実際の読み取りAPIを呼び出し、成否で判定。作成・変更・削除は行いません）
----------------------------------------------------------------------
ACTION                         DECISION      RESOURCE                   NOTE
------------------------------ ------------- -------------------------- ----
s3:ListAllMyBuckets            allowed       *                          実APIコール結果
s3:ListBucket                  skipped       *                          --s3-bucket 未指定のためライブ確認不可
ec2:DescribeInstances          denied        *                          実APIコールが権限不足で拒否された
logs:DescribeLogGroups         denied        *                          実APIコールが権限不足で拒否された
...
```

---

## 判定（DECISION）の意味

| 判定 | 意味 | 出る方式 |
| --- | --- | --- |
| `allowed` | 許可（ポリシー上、実行可能） | simulate / live |
| `explicitDeny` | 明示的な拒否（Deny ステートメントにより禁止） | simulate |
| `implicitDeny` | 暗黙の拒否（許可が無いため不可） | simulate |
| `denied` | 実 API コールが権限不足で失敗 | live |
| `skipped` | 対象未指定・主体タイプ非該当などで確認をスキップ | live |
| `unknown` | 判定不能（呼び出しエラー等） | simulate / live |

> `*`（全リソース）で評価しているアクションは、特定リソースに限定して許可されている場合に `implicitDeny` と表示されることがあります。`--s3-bucket` / `--resource-arn` でリソースを限定すると正確に評価できます。

---

## 確認できること / できないこと

**確認できること**

- 認証主体のアカウント ID / ARN / UserId と主体タイプ。
- （権限がある範囲で）主体に紐づくアタッチ済み管理ポリシー・インラインポリシー・所属グループ。
- 代表的な15アクション（s3 / ec2 / iam / lambda / cloudwatch / logs / **codecommit** / sts）に対する実効権限（許可 / 拒否）。CodeCommit は一覧・取得（読み取り）に加え、**作成（`codecommit:CreateRepository`）の権限有無も評価**します。

**確認できないこと（制約）**

- **保有する全権限の網羅的な列挙** — そのような単一 API は存在しません。本ツールは代表アクションのみを対象とします。
- セッションポリシー / SCP / 境界（permissions boundary）/ リソースベースポリシーの完全な反映 — 特に `simulate` ではアイデンティティベースの評価が中心となります。
- 条件キー（`Condition`）に依存する許可の厳密な評価 — 実環境のコンテキスト（送信元 IP、MFA 等）に左右されます。

---

## このツールが使用するAPIと必要なIAM権限

本ツールは以下の API のみを呼び出します（すべて読み取り / 評価系）。

- `sts:GetCallerIdentity`（どの主体でも常に許可されるため、ポリシー付与は不要）
- `iam:GetRole` / `iam:ListAttachedRolePolicies` / `iam:ListRolePolicies`（ロール主体の情報取得）
- `iam:GetUser` / `iam:ListAttachedUserPolicies` / `iam:ListUserPolicies` / `iam:ListGroupsForUser`（ユーザー主体の情報取得）
- `iam:SimulatePrincipalPolicy`（`simulate` 方式）
- `live` 方式で確認対象とする各読み取り API（`s3api list-buckets`、`ec2 describe-regions`、`codecommit list-repositories`、`codecommit get-repository` など）

これらの権限が無くても **ツール自体は停止せず**、該当セクションを「取得不可」「確認不可」として継続します。`[2] IAM情報` と `simulate` をフルに機能させたい場合の最小ポリシー例（読み取り専用）は次のとおりです。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSelfPermissionInspection",
      "Effect": "Allow",
      "Action": [
        "iam:GetUser",
        "iam:GetRole",
        "iam:ListAttachedUserPolicies",
        "iam:ListUserPolicies",
        "iam:ListGroupsForUser",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:SimulatePrincipalPolicy"
      ],
      "Resource": "*"
    }
  ]
}
```

> このポリシーは情報取得とシミュレーションのための読み取り専用です。リソースを変更する権限は含みません。組織のポリシーに応じて `Resource` を主体の ARN 等に絞ることも検討してください。

---

## セキュリティ

- 呼び出すのは **読み取り系 API と IAM ポリシーシミュレーション API のみ**。作成・変更・削除は行いません。
- **作成系アクション（`codecommit:CreateRepository`）の権限確認は `simulate`（ポリシー評価・実アクセスなし）でのみ行います。** `live` 方式では実際にリポジトリを作成してしまうため呼び出さず、必ず `skipped` と表示します。これによりツールの「読み取り専用」原則を保ったまま作成権限の有無を確認できます。
- アクセスキー / シークレットキー / セッショントークンを **一切表示しません**。
- IMDS やトークンの値をログ・標準出力に出しません。
- 一時ファイル（標準エラー退避用）は終了時に必ず削除します。

---

## 終了コード

| コード | 意味 |
| --- | --- |
| `0` | 正常終了（権限の有無に関わらず、確認処理が完了） |
| `1` | 認証失敗・前提コマンド不足など、確認を続行できない致命的エラー |
| `2` | 引数エラー |

---

## トラブルシューティング

| 症状 | 原因の例 | 対処 |
| --- | --- | --- |
| `AWS認証に失敗しました` で終了（コード1） | 資格情報が無効 / 期限切れ / 未ログイン | `aws login --remote` や `aws sso login --profile <name>` で再認証 |
| `シミュレーション権限がないため確認不可` | `iam:SimulatePrincipalPolicy` の権限が無い | `--mode live` を使うか、上記ポリシーを付与。`auto` なら自動で live にフォールバック |
| `s3:ListBucket` が `skipped` | `--s3-bucket` 未指定 | `--s3-bucket <name>`（GetObject は `--s3-key` も）を指定 |
| `codecommit:GetRepository` が `skipped` | `--codecommit-repo` 未指定 | `--codecommit-repo <name>` を指定。`ListRepositories` は指定不要 |
| `codecommit:CreateRepository` が常に `skipped`（live） | 作成系のため live では呼び出さない仕様 | `--mode simulate`（または `auto`）で作成権限の有無を評価 |
| リージョン依存 API が `unknown` | リージョン未解決 | `--region ap-northeast-1` または `AWS_REGION` を設定 |
| `iam:GetUser` が `skipped` | 主体が IAM ユーザーでない（ロール/SSO） | 仕様。ロール主体には `get-user` が適用されません |
| 特定バケットのみ許可なのに `implicitDeny` | `*` リソースで評価したため | `--s3-bucket` / `--resource-arn` でリソースを限定して再実行 |
| `必須コマンドが見つかりません: aws` | AWS CLI v2 未インストール / PATH 外 | AWS CLI v2 を導入し PATH を通す |

---

## 設計メモ・既知の制約

- **2方式の併用** — `simulate` はアクセスを発生させずに評価でき、`live` は SCP / セッションポリシー等を含む実際の挙動を反映します。両者は相互補完的で、`auto` は安全側（simulate 優先）から開始します。
- **`*` リソース評価の限界** — リソースレベルの許可（特定バケット等）は `*` 評価では `implicitDeny` になり得ます。リソースを明示指定すると正確に評価できます。
- **bash 3.2 互換** — macOS 標準 bash でも動かすため、連想配列・`mapfile`/`readarray`・`${var^^}` 等は使用していません。
- **エラー処理** — `set -Eeuo pipefail` + ERR/EXIT トラップを使用。`head`/`less` へのパイプで生じる SIGPIPE(141) はエラー扱いしません。

---

## ライセンス

社内利用を想定したユーティリティです。配布・改変の方針は組織のポリシーに従ってください。必要に応じて本セクションを `MIT` 等の正式なライセンス表記に差し替えてください。

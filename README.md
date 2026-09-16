# Apereo CAS 8.0.1 Local POC

这是一个可重复运行的本地 CAS 实验环境。默认路径使用 Apereo 发布的
`apereo/cas:8.0.1` 官方镜像；该镜像本身由 CAS WAR Overlay 生成。仓库同时保留
`cas/` Overlay 工程，供下一阶段增加 JSON Registry、LDAP 等模块时使用，但日常
POC 启动不需要在本机下载整套 Maven 依赖。

已实测的链路：

```text
测试用户认证 -> CAS session/TGT (TGC cookie) -> Service Ticket
             -> /serviceValidate -> 测试 Service 得到 casuser
```

## 版本与依赖

- CAS Server：`8.0.1`（镜像 tag 与 multi-arch digest 均锁定）
- CAS 容器：Java `25.0.3`、Spring Boot `4.1.0`、Jetty `12.1.11`
- Overlay Wrapper：Gradle `9.6.1`，Java 基线 `25`
- 本机需要：Docker Desktop、Docker Compose、curl、OpenSSL、Git
- 本机不需要安装 Java 或 Gradle；官方文档说明 Overlay 自带 Wrapper，默认运行
  又完全位于容器中

CAS 8.0.x 官方资料：

- [Installation Requirements](https://apereo.github.io/cas/8.0.x/planning/Installation-Requirements.html)
- [Docker Installation](https://apereo.github.io/cas/8.0.x/installation/Docker-Installation.html)
- [WAR Overlay Initializr](https://apereo.github.io/cas/8.0.x/installation/WAR-Overlay-Initializr.html)
- [JSON Service Registry](https://apereo.github.io/cas/8.0.x/services/JSON-Service-Management.html)

## 首次启动

确认 Docker Desktop 已运行，然后执行：

```bash
./scripts/start.sh
```

首次运行会：

1. 检查 Docker、Compose、curl 和 OpenSSL；
2. 创建 git 忽略的 `.env`，随机生成测试密码、keystore 密码和 CAS 会话密钥；
3. 在 `runtime/certs/` 生成 localhost 自签名证书与 PKCS#12 keystore；
4. 构建极小的测试 Service 镜像并启动两个容器；
5. 等待 CAS 和测试 Service 都真正可访问。

Compose 只把 `8443` 和 `8081` 发布到宿主机的 `127.0.0.1`；容器内的监听地址仍供
本项目 Compose 网络使用，不会主动把这两个端口发布到其他宿主机网络接口。

访问地址：

- CAS 登录页：<https://localhost:8443/cas/login>
- 测试 Service：<https://localhost:8081/>

浏览器会提示证书不受信任，因为它是脚本生成的本地自签名证书。确认目标确实为
`localhost` 后可仅为本地测试继续访问。脚本不会把证书安装到系统信任库；命令行
健康检查和协议回归通过 `curl --cacert runtime/certs/localhost.crt` 仅显式信任本项目
证书，同时保留正常的 hostname 校验。私钥不会被 Git 跟踪。

测试用户名默认为 `casuser`，密码查看本地 `.env`：

```bash
grep '^CAS_TEST_' .env
```

不要提交或分享 `.env`。

## 日常操作

```bash
./scripts/start.sh
./scripts/status.sh
./scripts/test-cas.sh
./scripts/stop.sh
```

- `start.sh` 可重复执行；保留已有账号、密钥和证书。
- `status.sh` 显示容器、端口和两个 HTTPS 端点的实际状态。
- `test-cas.sh` 无破坏地提交真实 CAS 登录 Webflow，检查 TGC，签发并验证两张
  不同的 ST，同时确认已消费的 ST 不能重放。
- `stop.sh` 停止并删除容器与 POC 网络，保留镜像、`.env`、证书和日志。

手工浏览器验证时访问测试 Service，它会跳转到 CAS；用 `.env` 中的账号登录后，
CAS 回跳 `/callback?ticket=ST-...`，测试 Service 调用 CAS `serviceValidate`，页面最终
显示认证用户名。

## 目录

```text
.
├── cas/                    # 官方 WAR Overlay 基线与固定 8.0.1 配置
│   ├── Dockerfile          # 可选：从 Overlay 构建完整 CAS 镜像
│   └── Dockerfile.runtime  # 默认：基于官方 8.0.1 已发布镜像
├── config/
│   ├── cas.properties      # 无硬编码密码的 CAS 本地配置
│   └── services/           # 下一阶段 Overlay JSON Registry 的服务定义
├── service/                # 仅用 Python 标准库的 CAS 测试客户端
├── scripts/                # start/status/test/stop 与证书脚本
├── docs/troubleshooting.md
├── docker-compose.yml
├── .env.example
└── runtime/                # 本地证书、私钥、keystore、CAS 日志；Git 忽略
```

CAS 文件日志位于 `runtime/logs/cas.log`、`runtime/logs/cas_audit.log`；容器日志：

```bash
docker compose logs -f cas
docker compose logs -f test-service
```

## 配置方式

### 当前默认 runtime

`./scripts/start.sh` 的实际运行链路是：

```text
docker-compose.yml
  -> cas/Dockerfile.runtime
  -> 官方 apereo/cas:8.0.1 runtime image
```

默认启动不会构建本仓库的完整 WAR Overlay。CAS 主要通过 `config/cas.properties`、
`.env` 和 `runtime/certs/` 配置；test-service 仍是 Python 标准库实现的最小 CAS
Client。

非敏感 CAS 设置在 `config/cas.properties`。密码和 Webflow/TGC 加密签名密钥只在
`.env` 中，通过 Spring 环境变量占位符注入。`.env` 是受 Git 忽略的本地明文配置，
`start.sh` 会把权限统一为 `600`，不会改写已有值。脚本目前以 Bash `source` 读取
`.env`；这个 Local POC 不引入额外 dotenv 依赖，因此值应只使用普通安全字符，不要
填写命令或 Bash 表达式。

当前服务注册依赖 `cas.service-registry.core.init-from-json=true`，将官方 WAR 内置的
HTTPS 示例 Service 导入内存注册表，重启时重新初始化；这适合本地 POC，不是生产
方案。

### 为未来扩展保留的 Overlay

`cas/` 中的 `Dockerfile`、Gradle 配置和 `src/` 是下一阶段扩展的 Overlay 基线。
只有需要 JSON Service Registry、LDAP、JDBC、自定义认证模块或其他 CAS module 时，
才切换 Compose 使用 `cas/Dockerfile` 来构建自己的 WAR Overlay；当前阶段不直接使用
这些文件启动 CAS。

`config/services/LocalTestService-1000.json` 是下一阶段切换到 Overlay 的显式服务
定义，匹配 `^https://localhost:8081/.*`。该目录当前没有挂载到默认 runtime，JSON
文件现在不生效，也没有和官方示例 Service 同时生效。未来启用它时，使用
`cas/Dockerfile` 构建包含
`cas-server-support-json-service-registry` 的 Overlay，并把该目录挂载到 CAS 后配置
`cas.service-registry.json.location=file:/etc/cas/services`。

## 完全重置

下面会删除本地账号密码、私钥、证书和日志，且不可恢复：

```bash
./scripts/stop.sh
docker compose down --rmi local --volumes --remove-orphans
rm .env
rm -r runtime
```

下次执行 `./scripts/start.sh` 会生成全新的本地材料。Docker 的全局 BuildKit 缓存
不属于本项目，重置命令不会清理它。

## 下一阶段

接入真实认证源时从 `cas/build.gradle` 增加官方模块开始，切换 Compose 到
`cas/Dockerfile` Overlay 构建，再在 `config/cas.properties` 加最小 LDAP/JDBC
配置。首先关闭静态测试认证：`cas.authn.accept.enabled=false`。不要在此基础上直接
当作生产配置；证书、Service Registry、ticket registry、密钥管理和高可用策略都需
重新设计。

本次实际遇到的故障见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 隔离的 Jamf X.509 TLS 准备

Stage 2A 只为 `docker-compose.x509.yml` 的 Tomcat X.509 connector 准备服务端信任环境，
不修改默认 `docker-compose.yml` / Jetty baseline。先从 macOS System Keychain 读取已知的
`UMU JSS Built-in Certificate Authority` 公钥证书并创建独立 JKS truststore：

```bash
./scripts/prepare-jamf-truststore.sh
docker compose -f docker-compose.x509.yml up -d --build
```

生成的 CA PEM、JKS truststore 以及随机密码分别保存在 git-ignored 的
`runtime/certs/` 和 `.env` 中。专用 connector 继续使用 `client-auth=want`，因此 9443
仍提供普通用户名密码登录，9444 负责可选客户端证书协商。

truststore 导入成功只表示 Tomcat 已具备信任锚配置；真实 Jamf Device Certificate
是否会被 Chrome 发送、是否能通过 Java/Tomcat TLS 校验，必须在 Stage 2B 由人工使用
公司 Mac 上的 System Keychain Identity 验证。

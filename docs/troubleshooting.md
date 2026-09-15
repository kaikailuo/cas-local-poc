# 本次搭建中实际遇到的问题

## Overlay release 内容与名称不一致

Apereo `cas-overlay-template` release `20260817123643` 的 release body 标为
`CAS: 8.0.1`，但归档内 `gradle.properties` 已写成 `8.1.0-SNAPSHOT`。处理方式是按
模板自身的 patch-release 指引，把 `version` 与 `cas.version` 显式固定为 `8.0.1`；
Java 25、Gradle 9.6.1、Spring Boot 4.1.0 与当时 Initializr 的 8.0 分支元数据一致。
详情记录在 `cas/UPSTREAM.md`。

## Overlay 首次构建下载停滞

模板 Dockerfile 以 Zulu JDK 25 为基础，却又通过 `jvmVendor=AMAZON` 请求第二套
Corretto toolchain。当前网络下 Gradle 配置阶段长时间无进展。Overlay 已调整为使用
容器中现成、CAS 官方支持的 Zulu 25，并给 `/root/.gradle` 配置 BuildKit cache mount。

为了先完成可运行 POC，默认 Compose 使用官方 `apereo/cas:8.0.1` 镜像；Overlay
构建保留为后续扩展路径。

## 官方 Overlay Dockerfile 缺少源目录

Dockerfile 无条件复制 `etc/cas/services/` 与 `etc/cas/saml/`，而模板归档中没有这
两个目录，BuildKit 报 `not found`。在两个目录中加入 `.gitkeep` 后解决。

## CAS 启动时报 PKCS#12 BadPaddingException

最初只设置了 `server.ssl.key-store-password`。Jetty 读取私钥时还需要
`server.ssl.key-password`；缺失时出现 `UnrecoverableKeyException` 和
`BadPaddingException`。两项都引用 `.env` 中同一个随机 keystore 密码后启动成功。

如果手工替换 keystore，确保 store password、key password 与配置一致。

## 带 service 参数访问登录页得到 403

日志显示内存注册表加载了 0 个服务，并明确记录 `Service is not registered`。官方
WAR 内含 `services/HTTPSandIMAPS-10000001.json`，但默认未导入当前内存注册表。
设置 `cas.service-registry.core.init-from-json=true` 后启动日志显示加载 1 个服务，
本地 HTTPS 测试 Service 获得授权。

## 测试 Service 误报 ticket 验证失败

CAS `/serviceValidate` 已返回成功 XML，但测试代码把协议 namespace 写成了 HTTPS。
CAS XML namespace 实际为 `http://www.yale.edu/tp/cas`。修正后能够解析
`authenticationSuccess/user`。

## 测试 Service 重建后偶发 connection reset

Compose 的 `Started` 表示容器进程已启动，不代表 Python TLS socket 已完成监听。
脚本曾在这个极短窗口连接并收到 reset。`start.sh` 和 `test-cas.sh` 现在都会轮询 CAS
与测试 Service 两个端点，避免启动竞态。

## 仍然可见的预期警告

- 静态 Accept Users 认证不适合生产：这是本 POC 的预期配置。
- 内存 service/ticket registry 不适合集群：本 POC 为单节点且重启可丢失票据。
- Log4j package scanning deprecated：来自官方镜像内置 `log4j2.xml`，不影响本次验证。


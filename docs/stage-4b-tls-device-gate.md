# Stage 4B — TLS Device Gate + User Principal 验收报告

验收日期：2026-09-17  
CAS：8.0.1  
范围：官方 CAS Overlay、Spring Boot 与 embedded Tomcat 配置；不含自定义认证代码。

## Stage 4B 结论

`TLS_GATE_PARTIAL`

以下链路已在真实公司 Mac、Chrome、System Keychain 中的 Jamf Device Certificate 上
端到端成立：

```text
Jamf client certificate
-> Tomcat/JSSE mutual TLS
-> CAS username/password login
-> UsernamePasswordCredential
-> principal casuser
-> TGT
-> ST
-> serviceValidate principal casuser
```

不能分类为 `TLS_GATE_SUFFICIENT`，因为 Stage 4B 不执行 CAS X.509 Handler，所以 Stage 3
的 Subject regex 不再执行；仓库、证书链与已有材料也不能证明当前 Jamf CA 只签发目标
Jamf Device Certificate。TLS device gate 与用户身份链路本身已经成立。

## 实际链路

```text
Chrome Jamf Identity:
PASS

Client Certificate sent:
PASS

TLS handshake:
PASS

Tomcat trust:
PASS

CAS Login Page:
REACHED

X509CertificateCredential:
NOT CREATED

X509 Handler:
NOT EXECUTED

UsernamePasswordCredential:
CREATED

User Handler:
PASS

TGT:
CREATED

TGT Principal:
casuser

ST:
CREATED

serviceValidate Principal:
casuser
```

真实 Chrome 请求来自 Docker gateway 地址 `172.20.0.1`。CAS 在
2026-09-17 10:19:35 UTC 记录：

- `UsernamePasswordCredential(username=casuser, ...)`；
- `Authenticated principal [casuser]`；
- `AUTHENTICATION_SUCCESS`；
- `TICKET_GRANTING_TICKET_CREATED`，`WHO: casuser`；
- `SERVICE_TICKET_CREATED`，`WHO: casuser`；
- `Granted service ticket ... and principal [casuser]`。

Test Service 收到该 ST 的 callback，并通过未发布到宿主机的容器内部 connector 调用
`/serviceValidate`。CAS 随后记录：

- `SERVICE_TICKET_VALIDATE_SUCCESS`；
- `PROTOCOL_SPECIFICATION_VALIDATE_SUCCESS`；
- `principal=casuser`。

浏览器最终页面显示：

```text
CAS login succeeded
Authenticated user: casuser
Service ticket ... was validated exactly once.
```

这不是根据 HTTP 200 单独推断成功。

## X.509 CAS Authentication 未执行的证据

Stage 4B Overlay 使用 `-PwithoutX509=true` 构建。最终运行镜像中不存在：

```text
cas-server-support-x509-webflow-8.0.1.jar
cas-server-support-x509-8.0.1.jar
cas-server-support-x509-core-8.0.1.jar
```

镜像仍包含官方 embedded Tomcat module：

```text
cas-server-webapp-init-tomcat-8.0.1.jar
```

Stage 4B 全部 CAS/audit 日志均没有 `X509CertificateCredential` 或
`X509CredentialsAuthenticationHandler`。因此证书虽然作为 servlet TLS 层的客户端证书
存在，但没有被转换成 CAS credential，也没有进入 CAS Authentication。

## No-Certificate Test

```text
TLS:
FAIL

CAS Login Page:
NOT REACHED

UsernamePasswordCredential:
NOT CREATED

TGT:
NOT CREATED

ST:
NOT CREATED
```

最终配置上，curl 不提交客户端证书时，Tomcat 先发送 TLS `CertificateRequest`，随后
拒绝空 client certificate；curl exit code 为 56，响应体为 0 字节。测试前后 CAS 主
日志行数不变，证明请求没有进入 CAS Webflow。

## Non-Jamf Certificate Test

使用仓库已有的 localhost 自签名服务证书作为安全的非 Jamf client certificate：

```text
TLS:
FAIL

TLS alert:
certificate unknown

CAS Login Page:
NOT REACHED

TGT / ST:
NOT CREATED
```

curl exit code 为 56，响应体为 0 字节；测试前后 CAS 主日志行数不变。该证书不链到
Jamf truststore 中唯一的信任锚，因此被 Tomcat/JSSE 拒绝。

## TLS Security Boundary

### Private Key Possession

由 Chrome 与 Tomcat/JSSE 的 TLS handshake 验证。Chrome 使用 macOS System Keychain
中的 Jamf 私钥生成 TLS `CertificateVerify` 签名；Tomcat/JSSE 使用 leaf certificate
中的公钥验证签名。钥匙串授权密码只是在本机授权 Chrome 使用私钥，不是 CAS 用户认证。

### Certificate Validity

由 Tomcat 默认 JSSE trust manager 的 PKIX client-certificate validation 检查证书有效
期。Stage 4B 没有 CAS Handler 的第二次 `checkValidity()`。

### Trusted CA

由 Tomcat/JSSE 根据独立 JKS truststore 验证。该 truststore 只导入：

```text
Subject/Issuer: CN=UMU JSS Built-in Certificate Authority
SHA-256: 55:E2:C2:4C:49:B4:3E:E9:16:04:15:8F:DB:A5:07:FD:
         DD:A8:DE:D7:FA:2A:C5:31:07:F9:1D:67:96:4C:15:D9
```

非 Jamf localhost client certificate 的反向测试实际得到 `certificate unknown`。

### KeyUsage

由 OpenJDK JSSE TLS client end-entity checker 在 KeyUsage 扩展存在时检查 TLS client
签名用途；当前 Jamf leaf 已观测到 critical `Digital Signature`。这不是 Stage 3 的
CAS `cas.authn.x509.check-key-usage` policy；Stage 4B 中该 CAS policy 完全不存在。

JSSE 对“扩展存在时检查”不等价于 Stage 3 CAS `require-key-usage=true` 所表达的
“扩展必须存在”。当前没有错误 KeyUsage 证书可做独立 TLS negative test。

### ExtendedKeyUsage / TLS Web Client Authentication

由 OpenJDK JSSE TLS client end-entity checker 在 EKU 扩展存在时检查 `clientAuth`
或 `anyExtendedKeyUsage`。当前 Jamf leaf 已观测到 `TLS Web Client Authentication`
（OID `1.3.6.1.5.5.7.3.2`）。当前没有错误 EKU 证书可做独立 TLS negative test。

### Revocation

当前 Tomcat/JSSE connector 没有配置 OCSP/CRL revocation mechanism；Stage 4B 又没有
CAS X.509 revocation checker。因此当前边界不证明证书尚未被 Jamf 撤销。

## HTTP/2

最初的 HTTP/1.1 实测中，Chrome 首次 mTLS 连接能到达登录页，但页面并行连接中的部分
client-certificate handshake 被关闭，提交表单时出现 `ERR_SOCKET_NOT_CONNECTED`；
Tomcat access log 只有无 HTTP request line 的 400，没有收到登录 POST。

使用 Spring Boot 官方属性：

```properties
server.http2.enabled=true
```

后，9445 实测 ALPN 为 `h2`，仍然发送 TLS client `CertificateRequest`。Chrome 的登录
页资源和表单 POST 均通过 HTTP/2，最终 POST 返回 302 并完成完整 CAS 协议链。HTTP/2
没有改变 `server.ssl.client-auth=need` 或 truststore。

## 内部 Protocol Connector

浏览器唯一发布入口为：

```text
127.0.0.1:9445 -> CAS/Tomcat 8443, HTTPS, client-auth=need
```

CAS 另使用官方 `cas.server.tomcat.http[0]` 配置建立容器内部 HTTP 8080 connector，供
Test Service 服务端调用 `/serviceValidate`。8080 没有映射到宿主机，仅 Stage 4B Docker
network 可达；否则 Test Service 自身也必须持有 Jamf 设备私钥，无法完成标准 CAS
服务端 ticket validation。

这个内部 connector 是 POC 的 network boundary，不应在生产中公开；生产部署应以网络
策略只允许受信任 CAS client/service backend 访问相应 protocol endpoint。

## 当前 Device Trust 实际代表什么

当前 Device Trust 代表：客户端在握手时持有一张处于有效期内、可链到当前 Jamf CA
truststore、并满足 JSSE TLS client-certificate 用途检查的证书及其私钥，因而获准进入
公网 CAS 用户登录入口。

## 当前 Device Trust 不代表什么

- 不代表设备当前仍在 Jamf active/enrolled；
- 不代表设备当前 compliant；
- 不代表证书未被 Jamf 撤销；
- 不代表 leaf Subject 一定为 `CN=<UUID>, O=UMU`；
- 不代表该 CA 只签发目标类型的 Jamf Device Certificate；
- 不代表设备属性或 Jamf inventory 状态得到实时验证。

## Subject Policy

是否仍检查：

```text
CN=<UUID>, O=UMU
```

`NO`

```text
Subject Policy = NOT ENFORCED AT CAS APPLICATION LAYER
```

Stage 4B 不包含 X.509 CAS modules/Handler，因此 Stage 3 的
`cas.authn.x509.reg-ex-subject-dn-pattern` 不执行。TLS PKIX validation 不等价于该
Subject regex。

## Jamf CA 专用性

`UNKNOWN`

现有证据只证明：

- System Keychain 中存在名称为 `UMU JSS Built-in Certificate Authority` 的自签名
  CA certificate；
- 其 SHA-256 fingerprint 与脚本固定值一致；
- Stage 4B JKS 只导入这一信任锚；
- 真实目标 Jamf leaf 可链到该信任锚；
- 非 Jamf localhost certificate 被拒绝。

仓库、CA certificate/leaf chain 和已有材料都没有 CA issuance scope、certificate
profile 或 Jamf 配置证据，不能证明该 CA 只签发目标 Jamf Device Certificate。不得从
CA 名称自行推断其专用性。

## 自定义代码

Java：

```text
NO
```

Gateway：

```text
NO
```

Custom Handler：

```text
NO
```

Custom TrustManager：

```text
NO
```

MFA Provider：

```text
NO
```

同样没有自定义 Webflow、Filter 或 CAS 源码修改。

## 本阶段证明了什么

本阶段证明了可仅用 CAS/Spring Boot/embedded Tomcat 官方配置，把真实 Jamf 客户端证书
作为强制 TLS 前置门槛，同时让 CAS 仅使用用户名密码建立 `casuser` Principal，并完成
TGT、ST 与 `serviceValidate`。

## 本阶段没有证明什么

本阶段没有证明该证书代表实时 Jamf enrollment/compliance，也没有恢复 Stage 3 的 leaf
Subject regex 或证明 Jamf CA 的签发范围只包含目标设备证书。

## Git 修改

- `cas/build.gradle`：增加 `withoutX509` Overlay 构建开关；默认 Stage 3 构建仍包含原生
  X.509 webflow，Stage 4B 构建明确不包含所有 CAS X.509 modules。
- `config/cas-stage4b.properties`：新增隔离的 Tomcat mTLS `need`、Jamf truststore、
  HTTP/2、Accept Users 与容器内部 protocol connector 配置。
- `config/services-stage4b/Stage4BTlsGateService-4002.json`：新增只匹配 9082 callback、
  不含 required-handlers/X.509 policy 的隔离 Registered Service。
- `docker-compose.stage4b.yml`：新增隔离的 9445 CAS 与 9082 Test Service 环境；不修改
  baseline Compose 或 Stage 3 Compose。
- `docs/stage-4b-tls-device-gate.md`：本验收报告。

Stage 4A 报告已预先独立提交：

```text
5c4bf02 docs(cas): record native device user auth investigation
```

## 建议 Commit

```text
feat(cas): enforce device certificate at tls boundary
```

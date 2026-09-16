# Stage 3 — Jamf Device Certificate X.509 Policy 验收报告

验收日期：2026-09-16  
CAS：8.0.1（Apache Tomcat 11.0.24，Azul Zulu OpenJDK 25.0.3）

## Stage 3 结论

**PASS**

CAS 原生 X.509 policy 已能够在 TLS 信任链验证之外，对 Jamf Device
Certificate 的 Subject、Issuer 和 X.509 KeyUsage 实施额外准入限制；Subject 与
Issuer 均已分别通过真实证书的正向和反向测试。没有增加自定义 Java、Gateway 或
TrustManager，也没有进入 Device + User Authentication 或 Stage 4。

## Stage 2B 实际状态基线

以下值来自 2026-09-16 06:59:43 的真实 CAS 日志，而不是从配置推测：

- Authentication Handler：`X509CredentialsAuthenticationHandler`
- Credential：`X509CertificateCredential`
- Principal type：`SUBJECT_DN`（当时为默认值，本阶段已显式配置）
- 最终 Principal ID：`CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU`
- Subject：`CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU`
- Subject X500Principal：`CN=95AD3B07-FBA8-43A1-917D-52777E74D803,O=UMU`
- Issuer：`CN=UMU JSS Built-in Certificate Authority`
- 成功事件：`AUTHENTICATION_SUCCESS`
- Ticket 事件：`TICKET_GRANTING_TICKET_CREATED`

因此，当前 CAS X.509 Principal 是**完整 DN**，不是 UUID-only。UUID 是 DN 的 CN
值，但没有单独成为最终 Principal ID。

Handler 名称的确认依据也不是配置猜测：`cas.authn.x509.name` 未设置时，CAS 8.0.1
的 `AbstractAuthenticationHandler` 使用实际类的 simple name，运行日志又明确打印了
`X509CredentialsAuthenticationHandler`。

## 当前 Device Certificate Policy

正式配置：

```properties
cas.authn.x509.reg-ex-subject-dn-pattern=^CN=[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}, O=UMU$
cas.authn.x509.reg-ex-trusted-issuer-dn-pattern=^CN=UMU JSS Built-in Certificate Authority$
cas.authn.x509.principal-type=SUBJECT_DN
cas.authn.x509.subject-dn.format=DEFAULT
cas.authn.x509.check-key-usage=true
cas.authn.x509.require-key-usage=true
cas.authn.x509.revocation-checker=NONE
```

UUID pattern 约束为标准的 `8-4-4-4-12` 十六进制结构，同时接受大小写十六进制。

### DN 顺序

证书的人类描述可写成 `O=UMU, CN=<UUID>`，但本环境实际的 Java/CAS 字符串不是该
顺序。真实日志中的 `subjectDn` 是：

```text
CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU
```

本阶段显式保留 `cas.authn.x509.subject-dn.format=DEFAULT`。CAS 8.0.1 的 Subject
policy 实现直接对 `certificate.getSubjectDN().getName()` 使用 Java
`Matcher.matches()`；Principal resolver 的 `DEFAULT` 格式同样保留了已验收的完整
DN Principal。正则因此按实际 `CN=..., O=UMU` 制定，而不是按证书查看器的肉眼顺序。

## TLS 层与 CAS Handler 层的职责

### TLS / Tomcat / JSSE

9444 connector 使用：

- `client-auth=want`：请求客户端证书，但无证书时仍允许 TLS 建连并进入 mixed-mode；
- 独立 JKS truststore：只放入已验收的 Jamf issuing CA；
- 默认 Tomcat JSSE trust manager，没有 Custom TrustManager；
- 对收到的客户端证书执行证书链、信任锚、证书有效期、签名/算法约束和 TLS client
  用途检查；
- OpenJDK TLS client end-entity 检查在 KeyUsage 存在时要求 digitalSignature，在 EKU
  存在时要求 `clientAuth` 或 `anyExtendedKeyUsage`。扩展缺失时该层并不等价于“扩展
  必须存在”。

Tomcat 文档说明默认 SSL implementation 是 JSSE，truststore 用于验证客户端证书；
OpenJDK `EndEntityChecker.checkTLSClient` 明确区分 KeyUsage 与 ExtendedKeyUsage。

### CAS X.509 Handler

证书已经通过 TLS 后，CAS 8.0.1 原生 Handler 又执行：

- 每张证书的 `X509Certificate.checkValidity()`；
- leaf Subject 完整匹配；
- trusted Issuer 完整匹配；
- `check-key-usage=true` 与 `require-key-usage=true`：要求 KeyUsage 扩展存在，并要求
  bit 0 `digitalSignature=true`；
- `revocation-checker=NONE`，即本阶段没有 CAS CRL revocation check；
- 通过 `SUBJECT_DN` 解析完整 DN Principal。

证书有效期因此并非只由单一层负责：TLS/JSSE 的证书路径校验负责一次，CAS Handler
又显式调用 `checkValidity()`。

## Positive Test

测试材料：System Keychain 中的真实 Jamf Device Certificate。最终回归时间：
2026-09-16 08:35:26 UTC。

TLS：  
**PASS**

Subject Policy：  
**PASS** — 日志显示正式 Subject regex 对实际 Subject 的匹配结果为 `true`。

Issuer Policy：  
**PASS** — 日志显示正式 Issuer regex 对实际 Issuer 的匹配结果为 `true`。

X509 Authentication：  
**PASS** — `DefaultAuthenticationManager` 记录通过
`X509CertificateCredential` 认证完整 DN Principal，并出现该 credential 的
`AUTHENTICATION_SUCCESS`。

TGT：  
**CREATED** — 随后出现 `TICKET_GRANTING_TICKET_CREATED`。

该请求能够进入 Handler 并完成上述事件，也证明 Chrome identity、TLS handshake、
Tomcat trust 与 Servlet `X509Certificate` 传递均已通过。

## Negative Test

### Wrong Subject

临时配置：

```properties
cas.authn.x509.reg-ex-subject-dn-pattern=^CN=00000000-0000-0000-0000-000000000000, O=NOT-UMU$
```

测试时间：2026-09-16 08:02:31 UTC。测试后已恢复正式 Subject policy。

TLS：  
**PASS**

CAS X509：  
**FAIL（预期拒绝）**

TGT：  
**NOT CREATED（该 X.509 Authentication）**

证据链：

1. Handler 收到并 `Evaluating` 同一真实证书，证明 TLS、Tomcat trust 和 Servlet
   certificate 传递已通过；
2. 日志显示错误 Subject regex 对真实 Subject 的匹配结果为 `false`；
3. Handler 记录 `Certificate subject does not match pattern`；
4. 审计记录 `AUTHENTICATION_FAILED`，该事件之后没有由该 X.509 authentication
   产生的 `AUTHENTICATION_SUCCESS` 或 TGT；
5. 浏览器回退到用户名密码登录页。这是 X.509 failure 后的 mixed-mode fallback，
   页面可返回 HTTP 200，但不代表认证成功。

这证明 Subject policy 是在 TLS 信任成功后由 CAS Handler 独立执行的准入限制。

### Wrong Issuer Policy

临时配置：

```properties
cas.authn.x509.reg-ex-trusted-issuer-dn-pattern=^CN=Definitely Not The Jamf Issuer$
```

测试时间：2026-09-16 08:25:33 UTC；08:28 与 08:30 的重复请求得到相同结果。测试后
已恢复正式 Issuer policy。

TLS：  
**PASS**

CAS X509：  
**FAIL（预期拒绝）**

TGT：  
**NOT CREATED（该 X.509 Authentication）**

证据链：

1. 同一证书再次进入 Handler；
2. 正式 Subject regex=`true`，KeyUsage 检查也已执行；
3. 错误 Issuer regex 对真实 Issuer 的匹配结果为 `false`；
4. Handler 记录无法定位 trusted issuer，审计记录 `AUTHENTICATION_FAILED`；
5. 没有该 X.509 authentication 的 `AUTHENTICATION_SUCCESS` 或 TGT。

测试期间 mixed-mode 页面另有一次 `casuser` 用户名密码登录，产生了属于
`UsernamePasswordCredential` 的 TGT。它是独立 fallback 认证，不能算作被拒绝的
X.509 credential 创建了 TGT，也不改变 Negative Test 结论。

这证明 `reg-ex-trusted-issuer-dn-pattern` 在当前 CAS 8.0.1 环境中按预期工作，并且
没有改变 Tomcat truststore 或 TLS 信任结果。

## Principal

实际 CAS X.509 Principal：

```text
CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU
```

类型：**完整 DN**。

不是 UUID-only；UUID `95AD3B07-FBA8-43A1-917D-52777E74D803` 只是 CN。

## KeyUsage / EKU

真实 Jamf Device Certificate（直接读取 System Keychain 中的公开证书）：

- KeyUsage：critical，`Digital Signature`
- ExtendedKeyUsage：`TLS Web Client Authentication`（OID `1.3.6.1.5.5.7.3.2`，
  即 `clientAuth`）
- BasicConstraints：critical，`CA:FALSE`
- 有效期：2026-08-20 03:18:40 UTC 至 2028-08-21 03:18:40 UTC

CAS 实际检查：

- `cas.authn.x509.check-key-usage` 调用 `X509Certificate.getKeyUsage()`；
- CAS 8.0.1 实现只检查 KeyUsage bit 0，即 `digitalSignature`；
- `require-key-usage=true` 使 KeyUsage 缺失也失败；
- **CAS 这项检查不是 ExtendedKeyUsage/clientAuth 检查**。

TLS 实际检查：

- Tomcat 默认 JSSE trust manager 执行 TLS client certificate 校验；
- OpenJDK 的 TLS client end-entity checker 分别检查 KeyUsage digitalSignature 和
  ExtendedKeyUsage clientAuth/anyExtendedKeyUsage（扩展存在时）；
- 本证书两个扩展都符合，真实 TLS handshake 已成功。

仍未知 / 未独立证明：

- 没有第二张安全可用的、只缺少或错误设置 KeyUsage/EKU 的 Jamf-signed client
  certificate，因此没有进行 KeyUsage 或 EKU 的独立 negative TLS test；
- CAS KeyUsage 状态记录为：**configured/observed but negative behavior not
  independently proven**；
- CAS 8.0.1 原生 X.509 属性中没有发现可单独表达“EKU 必须包含 clientAuth”的
  Handler policy；本阶段没有为此编写自定义实现；
- TLS 对 clientAuth EKU 的结论来自 Tomcat/JSSE 运行路径与 OpenJDK 实现语义，当前
  真实证书只完成了正向验证，未完成错误 EKU 的独立反向验证。

## Revocation

当前状态：**NONE**

```properties
cas.authn.x509.revocation-checker=NONE
```

当前 CAS Handler 不读取证书 CRL Distribution Points，也不使用固定 CRL resource；
Tomcat JSSE connector 也没有配置本阶段的 OCSP/CRL revocation mechanism。因此，如果
设备已经从 Jamf 撤销或退管，但证书仍在有效期内且私钥仍可用，现有方案不能实时感知
Jamf enrollment/compliance 状态。

**Stage 3 的 device trust 目前代表“持有一张有效且符合 Jamf Certificate Policy 的
证书”，不等同于“设备当前仍处于 Jamf active/compliant 状态”。**

本阶段没有连接 Jamf API。

## 自定义代码

Java：**否**  
Gateway：**否**  
Custom TrustManager：**否**

全部 policy 都使用 CAS 8.0.1 自带的 X.509 properties 与 Handler。

## 本阶段证明了什么

CAS 原生 X.509 policy 已能够在 TLS 信任链验证之外，对 Jamf Device Certificate 的
Subject、Issuer 等属性实施额外准入限制，并通过正反测试验证。

## 本阶段没有证明什么

- 尚未证明设备身份与用户身份能够同时作为最终 CAS Service Authentication 条件；
- 尚未证明实时 Jamf enrollment/compliance 状态；
- 尚未独立反向证明错误 KeyUsage/EKU 证书的具体拒绝行为；
- 没有进入 Stage 4。

## Git 修改

- `config/cas-x509.properties`：加入正式 Jamf Subject/Issuer policy；显式固定
  `SUBJECT_DN` / `DEFAULT`；启用并要求 X.509 KeyUsage；显式记录 revocation `NONE`。
- `cas/etc/cas/config/log4j2.xml`：仅为 CAS 原生 X.509 Handler 启用 DEBUG，留下
  Subject/Issuer 匹配与 KeyUsage 执行证据，不扩大整个 CAS 的日志级别。
- `docs/stage-3-x509-policy.md`：记录 Stage 3 调查、正反测试证据、边界与结论。
- `README.md`：增加 Stage 3 正式 policy 与验收报告入口。

## 建议 Commit

```text
feat(cas): enforce jamf device certificate x509 policy
```

## 参考实现与配置资料

- [CAS 8.0.x X.509 Authentication](https://apereo.github.io/cas/8.0.x/authentication/X509-Authentication.html)
- [CAS 8.0.x X.509 Principal Resolution](https://apereo.github.io/cas/8.0.x/authentication/X509-Authentication-Principal-Resolution.html)
- [Tomcat 11 HTTP Connector TLS configuration](https://tomcat.apache.org/tomcat-11.0-doc/config/http.html)
- [OpenJDK EndEntityChecker TLS client checks](https://github.com/openjdk/jdk/blob/master/src/java.base/share/classes/sun/security/validator/EndEntityChecker.java)

除公开资料外，本报告对 CAS Handler 的细节以运行容器内
`cas-server-support-x509-core-8.0.1.jar`、
`cas-server-support-x509-8.0.1.jar` 与
`cas-server-core-api-configuration-model-8.0.1.jar` 的实际 metadata/bytecode 为准。

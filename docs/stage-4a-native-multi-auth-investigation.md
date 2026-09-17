# Stage 4A — CAS 原生 Device + User Authentication 调查报告

调查日期：2026-09-16  
CAS：8.0.1  
范围：仅调查、JAR/class 检查与隔离配置实验；不实现最终方案。

## Stage 4A 结论

**PURE_CONFIG_NOT_SUFFICIENT**

CAS 8.0.1 当前的 X.509 mixed-mode、Registered Service Authentication Policy 与
`AllAuthenticationHandlersRegisteredServiceAuthenticationPolicyCriteria`，不能仅靠现有
properties/JSON 表达并执行以下目标：

```text
Jamf Device X.509 Authentication SUCCESS
AND
User Authentication SUCCESS
-> User Principal
```

真实实验反而证明：Service 同时列出 `Static Credentials`（Accept Users Handler 的
运行名称）与 `X509CredentialsAuthenticationHandler` 后，只有 X.509 credential 的
transaction 仍满足 `All` policy，随后创建了 ST，并向 Service 返回设备 DN。

## Stage 3 当前认证对象

2026-09-16 09:42:45 UTC 使用正式 Jamf X.509 policy 重新完成认证。真实运行对象为：

- Credential：`X509CertificateCredential`
- Handler：`X509CredentialsAuthenticationHandler`
- Principal：`CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU`
- Principal attributes：
  - `issuerDn=[CN=UMU JSS Built-in Certificate Authority]`
  - `issuerX500Principal=[CN=UMU JSS Built-in Certificate Authority]`
  - `sigAlgOid=[1.2.840.113549.1.1.11]`
  - `subjectDn=[CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU]`
  - `subjectX500Principal=[CN=95AD3B07-FBA8-43A1-917D-52777E74D803,O=UMU]`
- Authentication attributes：
  - `credentialType=[X509CertificateCredential]`
  - `authenticationMethod=[X509CredentialsAuthenticationHandler]`
  - `successfulAuthenticationHandlers=[X509CredentialsAuthenticationHandler]`
  - `authenticationDate`、`clientIpAddress`、`serverIpAddress`、`userAgent`、
    `geoLocation`
- 成功事件：`AUTHENTICATION_SUCCESS`
- TGT：`TGT-4-...`，随后记录 `TICKET_GRANTING_TICKET_CREATED`

**是。当前 X.509 成功创建 TGT 后，Authentication 中只有
`X509CredentialsAuthenticationHandler` 的成功记录。** 没有
`UsernamePasswordCredential`，也没有 `Static Credentials` 成功记录。

人工操作中出现的钥匙串用户名/密码提示是 macOS 对客户端证书私钥的本机授权，不是
CAS Username/Password 登录。CAS 日志也确认没有生成用户 credential。

## Mixed-mode 的真实语义

结论：**A，X.509 或 Username/Password 二选一/fallback；不是 B。**

CAS 8.0.1 的实际 Webflow/class 行为：

1. `X509WebflowConfigurer` 增加 `startX509Authenticate`；
2. X.509 成功转到 `createTicketGrantingTicket`，不会继续用户名密码阶段；
3. `X509CertificateCredentialsNonInteractiveAction` 在无证书或 X.509 失败时，依据
   `mixed-mode` 允许显示原登录表单；
4. 因此 mixed-mode 控制的是 X.509 不可用/失败时是否允许其他登录形式，不是把两种
   credential 串成一个最终 Authentication。

9444 的真实行为与实现一致：

- 正式 Jamf 证书成功时直接创建 device-principal TGT，没有 CAS 用户名密码页；
- Stage 3 Wrong Subject/Wrong Issuer 或无证书时回退到用户名密码页；
- 单独输入 `casuser` 时创建的是另一份仅含 `UsernamePasswordCredential` 的
  Authentication，而不是与此前失败/缺失的 X.509 合并。

## Registered Service Authentication Policy

隔离 Service 使用：

```json
"requiredAuthenticationHandlers": [
  "java.util.TreeSet",
  [
    "Static Credentials",
    "X509CredentialsAuthenticationHandler"
  ]
],
"criteria": {
  "@class": "org.apereo.cas.services.AllAuthenticationHandlersRegisteredServiceAuthenticationPolicyCriteria"
}
```

这里必须使用 `Static Credentials`，因为它是当前
`AcceptUsersAuthenticationHandler` 实例的实际 Handler name；类名不是 policy 匹配名。

CAS 8.0.1 的实际语义如下：

- `requiredAuthenticationHandlers` 先作为本次 transaction 的 Handler
  inclusion/allowlist；它不是待执行步骤清单，也不负责取得缺失的 credential。
- `AllAuthenticationHandlersRegisteredServiceAuthenticationPolicyCriteria` 被解析为
  `AllAuthenticationHandlersSucceededAuthenticationPolicy`。
- `AllAuthenticationHandlersSucceededAuthenticationPolicy` 比较的是本 transaction 中
  **支持现有 credential 的 current handlers** 与成功记录，而不是逐一要求 JSON 中
  每个 required handler name 都出现成功记录。
- 本次 X.509 transaction 虽然 inclusion resolver 先保留了两个 Handler，Accept Users
  不支持 `X509CertificateCredential`，所以 policy 实际记录为：

  ```text
  Successful authentications: [[X509CredentialsAuthenticationHandler]],
  current authentication handlers [X509CredentialsAuthenticationHandler]
  ```

  一对一相等，因此 `All` 判定成功。
- `AllAuthenticationHandlersRegisteredServiceAuthenticationPolicyCriteria` 本身没有
  `tryAll` 字段。带 `tryAll` 的相关 criteria/policy 中，该标志只约束已经提交的
  credentials 是否都被尝试并产生 success/failure；它不会获取第二个 credential，
  不会启动 Username/Password Webflow，也不把 required handler names 解释为 AND。
- 对已有 TGT，`RegisteredServiceAuthenticationPolicySingleSignOnParticipationStrategy`
  从 TGT 的 `successfulAuthenticationHandlers` 检查可用 SSO Authentication；
  `GenerateServiceTicketAction` 使用已有 Authentication 与当前 Webflow 已有
  credentials 建立结果。它不会因为 Service policy 中缺一个 Handler name 而主动
  收集新 credential。

因此，题设三个选项的真实答案是 **C：发生其他行为**。在本次精确配置下，CAS 没有
自动进入第二认证阶段，也没有认为 X.509-only Authentication 不满足；它认为 policy
已经满足并签发 ST。如果某项 policy 确实返回不满足，CAS 会拒绝该 policy/ST 或要求
重新认证，但仍不会自动构造“只补齐缺失 Handler”的 Username/Password 阶段。

## 当前流程

```text
Chrome 选择 Jamf Device Certificate
↓
macOS Keychain 解锁证书私钥（不是 CAS 用户认证）
↓
X509CertificateCredential
↓
X509CredentialsAuthenticationHandler = SUCCESS
↓
Principal = CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU
↓
TGT Authentication
  successfulAuthenticationHandlers = [X509CredentialsAuthenticationHandler]
↓
Stage 4A Service Policy
  required = [Static Credentials, X509CredentialsAuthenticationHandler]
  criteria = All
↓
All policy 实际只检查当前 credential 可用的 X509 Handler
↓
Policy PASS；没有 UsernamePasswordCredential
↓
ST CREATED + VALIDATED
↓
业务 Service Principal = device DN
```

## Required Handlers 实验

X509 Handler：  
**PASS**

User Handler：  
**NOT_EXECUTED**

是否出现用户认证：  
**NO**

最终 Authentication handlers：

```text
[X509CredentialsAuthenticationHandler]
```

最终 Principal：

```text
CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU
```

Service Ticket：  
**CREATED** — `ST-3-...`，且被 `/serviceValidate` 成功消费一次。

Service Validation Principal：

```text
CN=95AD3B07-FBA8-43A1-917D-52777E74D803, O=UMU
```

这不是把 HTTP 200 当成成功证据。CAS 同时记录了 `SERVICE_TICKET_CREATED`、
`SERVICE_TICKET_VALIDATE_SUCCESS`，测试 Service 明确显示 ST 被验证一次以及返回的
Principal。

另做的无客户端证书对照实验中，`casuser` 的
`UsernamePasswordCredential` 也能单独满足同一 Service policy，创建/验证 ST，最终
Principal 为 `casuser`，successful handlers 只有 `[Static Credentials]`。这进一步
证明该 JSON 在当前实现中得到的是“每个单 credential transaction 各自满足 All”，
不是“两种 credential 必须同时成功”。

## Principal 冲突

CAS 8.0.1 的结论不是简单的“所有 credentials 必须解析为同一 Principal”：

- `DefaultAuthenticationResultBuilder` 能聚合多份 credential 与多个成功 Handler
  result；顶层 `Authentication` 仍只有一个 canonical Principal。
- 当前默认 `DefaultPrincipalElectionStrategy` 使用 last conflict resolver。同一次、
  TGT 创建前的聚合中出现不同 Principal ID 时，默认会选最后一个，而不是天然要求
  两者相同。结果依赖认证分支/收集顺序，不等价于可靠地声明“用户永远是主身份”。
- 多个 Handler success/result 可以保留设备和用户认证的执行记录，但 ST/协议验证只
  释放最终 elected Principal；这不是两个并列的业务 Principal。
- TGT 已经以设备 DN 建立后，CAS 的
  `DefaultCentralAuthenticationService.evaluatePossibilityOfMixedPrincipals` 会比较新
  AuthenticationResult 与现有 TGT Principal。若后续结果为 `casuser`，不同 ID 会触发
  `MixedPrincipalException`，不会静默把设备 Principal 替换成用户 Principal。
- Service Ticket 使用 root TGT Authentication 的 Principal。本次运行已直接证明其
  最终关联和验证返回的是设备 DN。

因此：CAS 的 Authentication 数据结构能够记录多个 credential/handler success，但
当前原生 X.509 mixed-mode 没有生成所需的组合；在 X.509-first 且已经创建 device TGT
后，也不能靠后续 `casuser` 登录把顶层 Principal 改成用户。

## 核心问题

**仅使用当前 CAS 8.0.1 原生配置，能否实现：**

```text
Device Certificate PASS
AND
User Authentication PASS
-> User Principal
```

**NO。**

当前证据识别出以下缺口：

1. **Webflow 无法顺序执行两个认证阶段。** X.509 成功直接进入 TGT 创建；
   mixed-mode 只提供失败/缺失时的替代登录。
2. **Service Authentication Policy 只检查本次/已有 Authentication，不负责触发缺失
   的认证。** `requiredAuthenticationHandlers + All` 没有构成所需的两项 AND。
3. **Device Principal 与 User Principal 冲突。** 已建立 device-principal TGT 后，后续
   `casuser` 会落入 mixed-principal 防护，而非替换顶层 Principal。
4. **Authentication 表达与产生路径不一致。** 数据模型可以聚合多个成功记录，但当前
   原生 Webflow 没有产生“device proof + user primary identity”的组合状态；顶层
   Principal 也只能有一个。

## 原生 CAS 最接近的机制

### Registered Service Authentication Policy

能解决：限定 transaction 可使用哪些 Handler，并检查已经形成的 Authentication 是否
符合 criteria。  
不能解决：收集缺失的第二 credential、顺序启动第二阶段，或指定不同 Handler 结果中
哪个语义上必须是业务用户。

### Multiple Credentials

能解决：当同一认证过程实际提交多份 credentials 时，Authentication Manager 可以
逐一处理并由 policy 检查，Result Builder 可以聚合成功记录。  
不能解决：凭配置让当前 X.509 mixed-mode 自动再显示 Username/Password；也不能天然
保证两个不同 Principal 中 user 成为最终 Principal。

### Multifactor Authentication

能解决：CAS 的 MFA 架构天然表达“先有 primary user authentication，再依据
Service/request/principal 等条件进入第二认证阶段”，并在同一认证上下文中保留 primary
user identity。这在语义上最接近“用户是业务 Principal，设备持有证明是附加条件”。  
不能解决：当前启用的原生 X.509 adapter 是 primary/non-interactive authentication，
不是现成的 X.509 MFA Provider。调查中未发现只靠现有 properties/Service JSON 就能把
Jamf client certificate 转换为第二因子的内置 Provider。本阶段禁止且没有实现新的
MFA Provider。

### X.509 mixed mode

能解决：客户端无证书或 X.509 失败时允许回退到其他登录方式。  
不能解决：X.509 成功后继续用户认证，也不能表达 X.509 AND Username/Password。

## 是否应该视为 MFA

架构适配性结论：**应优先把语义理解为 Primary User Authentication + Device
Certificate possession proof 的 MFA-like condition，而不是 X.509 device Principal
作为 primary authentication 后再尝试替换成用户。**

CAS 官方 `All` policy 文档也把多 credential 的典型用途指向 multifactor 场景。这个
结论只说明建模方向更匹配；它没有证明 CAS 8.0.1 已存在可直接配置的 Jamf X.509 MFA
Provider，也不选择 Stage 4B 实现方案。

## 是否需要扩展

**当前证据表明可能需要最小扩展。**

只定位扩展点，不实现：让 Jamf X.509 proof 进入 CAS 原生 MFA/第二阶段认证边界，同时
保持 primary user Principal；或等价地提供一个受 CAS 原生认证生命周期管理的
device-condition 集成点。不能通过当前 Registered Service policy 或 mixed-mode 配置
完成。

## 自定义代码

Java：**否**  
Webflow：**否**  
Gateway：**否**  
MFA Provider：**否**

Filter：**否**  
AuthenticationHandler：**否**  
CAS 源码修改：**否**

## 本阶段证明了什么

本阶段证明了 CAS 8.0.1 的 X.509 mixed-mode 与 Registered Service `All` policy 不会把
Jamf 设备认证和用户认证串成 AND，且实测 ST 最终仍携带设备 DN Principal。

## 本阶段没有证明什么

本阶段没有证明任何自定义 MFA/最小扩展方案可行，也没有设计、实现或验收 Stage 4B。

## Git 修改

- `config/services/Stage4ARequiredHandlers-4001.json`：仅用于 Stage 4A 的隔离 Registered
  Service，匹配 `https://localhost:9081/callback`，不会匹配 baseline 8081 Service。
- `cas/etc/cas/config/log4j2.xml`：仅增加原生 policy、SSO、Authentication result 与
  ST 决策类的 DEBUG logger，用于留下 Stage 4A 运行证据。
- `docs/stage-4a-native-multi-auth-investigation.md`：本报告。

Stage 4A 修改未提交；Stage 3 已在 clean 状态提交为：

```text
18982e3 feat(cas): enforce jamf device certificate x509 policy
```

## 调查依据

官方资料：

- [CAS 8.0.x X.509 Authentication](https://apereo.github.io/cas/8.0.x/authentication/X509-Authentication.html)
- [CAS 8.0.x Registered Service Authentication Policy](https://apereo.github.io/cas/8.0.x/services/Configuring-Service-AuthN-Policy.html)
- [CAS 8.0.x All Authentication Policy](https://apereo.github.io/cas/8.0.x/authentication/Configuring-Authentication-Policy-All.html)
- [CAS 8.0.x Principal Election](https://apereo.github.io/cas/8.0.x/installation/Configuring-Principal-Election.html)
- [CAS 8.0.x Multifactor Authentication](https://apereo.github.io/cas/8.0.x/mfa/Configuring-Multifactor-Authentication.html)

运行实现检查以隔离容器内 CAS 8.0.1 JAR/class 为准，重点包括：

- `X509WebflowConfigurer`
- `X509CertificateCredentialsNonInteractiveAction`
- `RegisteredServiceAuthenticationHandlerResolver`
- `RegisteredServiceAuthenticationPolicyResolver`
- `AllAuthenticationHandlersSucceededAuthenticationPolicy`
- `RequiredAuthenticationHandlerAuthenticationPolicy`
- `RegisteredServiceAuthenticationPolicySingleSignOnParticipationStrategy`
- `GenerateServiceTicketAction`
- `DefaultAuthenticationResultBuilder`
- `DefaultPrincipalElectionStrategy`
- `DefaultCentralAuthenticationService`

最终判断同时以 9444 的真实 Jamf 证书认证、CAS audit/debug 日志、ST 创建事件和
`/serviceValidate` 返回 Principal 为准，而不是从属性名称或 HTTP 200 推测。

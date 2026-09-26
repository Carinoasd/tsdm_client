import 'package:tsdm_client/features/bank/models/bank_data.dart';

// Synthetic data follows the observed form structure; no live identities or credentials.
String bankDocument(String content, {int uid = 1000}) =>
    '''
<html><head><script>var discuz_uid = '$uid';</script></head><body>
<div class="tbn"><ul><li><font>Test coins:</font><span><b>800</b></span>(银行货币)</li></ul></div>
$content</body></html>''';

String bankDirectoryFixture() => bankDocument('''
<table id="ttt"><tr><td><h2>银行列表</h2></td></tr>
<tr><td>Logo</td><td>银行名称: Synthetic bank<br>银行行长: Synthetic manager<br>银行简介: Test</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=1">进入银行</a>已开户</td></tr></table>''');

String bankServiceFormFixture(
  BankService service, {
  String? operation,
  String token = 'synthetic-token',
  String extraHidden = '',
  bool record = false,
  int bankId = 1,
}) {
  final op =
      operation ??
      switch (service) {
        BankService.term => 'in',
        BankService.remittance => 'ok',
        BankService.loans => 'try',
        BankService.account => 'cg',
        BankService.interest => 'ok',
        _ => '',
      };
  final inputs = switch (service) {
    _ when record => [BankInput.password],
    BankService.hall => [BankInput.password, BankInput.passwordConfirm],
    BankService.interest => <BankInput>[],
    BankService.term || BankService.loans => [BankInput.amount, BankInput.days, BankInput.password],
    BankService.remittance => [BankInput.amount, BankInput.recipient, BankInput.password],
    BankService.account when op == 'cl' => [BankInput.password],
    BankService.account => [BankInput.password, BankInput.newPassword, BankInput.newPasswordConfirm],
    _ => <BankInput>[],
  };
  return '''<form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="$bankId">
<input type="hidden" name="action" value="${service == BankService.hall ? 'open' : service.action}">
${op.isEmpty ? '' : '<input type="hidden" name="op" value="$op">'}
<input type="hidden" name="formhash" value="$token">$extraHidden
${inputs.map((input) => '<input type="${input.secret ? 'password' : 'text'}" name="${input.field}">').join()}
${service == BankService.remittance ? '<button type="button" name="taxcheck" value="true">费用计算</button>' : ''}
<button type="submit" name="banksubmit" value="true">${record
      ? '支取'
      : service == BankService.hall
      ? '我要开户(开户费用:20)'
      : '提 交'}</button></form>''';
}

String bankServiceFixture(
  BankService service, {
  int uid = 1000,
  int bankId = 1,
  String token = 'synthetic-token',
  String? form,
  String? records,
  String rate = '2',
  String? operation,
}) {
  final actualForm =
      form ??
      (service.global ? '' : bankServiceFormFixture(service, token: token, bankId: bankId, operation: operation));
  final heading = service == BankService.hall ? '欢迎来到 Synthetic bank' : service.heading;
  final summary = service == BankService.remittance ? '当前汇款手续费率为$rate‰，欢迎使用本行汇款业务。' : '当前利率为1‰。';
  return bankDocument('''<table id="ttt"><thead><tr><td><h2>$heading</h2></td></tr></thead><tbody>
<tr><td class="footoperation">$summary</td></tr>
<tr><td>$actualForm</td></tr>
<tr><td class="footoperation">${service == BankService.term ? '我的定期记录' : '账户记录'}</td></tr>
<tr><td><table id="ttt">${records ?? '<tr><td><br><center>还没有相关数据。</center><br></td></tr>'}</table></td></tr>
<tr><td class="footoperation">注意事项</td></tr><tr><td>请核对操作，提交后查看记录。</td></tr>
</tbody></table>''', uid: uid);
}

Map<String, String> bankServiceInput(BankServiceForm form) => {
  for (final input in form.inputs)
    input.field: switch (input) {
      BankInput.amount => '100',
      BankInput.days => '30',
      BankInput.recipient => 'Synthetic recipient',
      _ => 'synthetic-password',
    },
};

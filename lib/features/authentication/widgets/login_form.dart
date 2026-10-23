import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/bloc/authentication_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/widgets/captcha_image.dart';
import 'package:tsdm_client/features/local_notice/notification_permission_prompt.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';

// TODO: Fetch login questions dynamically from web server.
final _loginQuestions = ['无安全问题', '母亲的名字', '爷爷的名字', '父亲出生的城市', '您其中一位老师的名字', '您个人计算机的型号', '您最喜欢的餐馆名称', '驾驶执照的最后四位数字'];

/// Text telling why a login failed, for the [exception] the authentication bloc reports.
String loginErrorText(BuildContext context, Object? exception) => switch (exception) {
  LoginFormHashNotFoundException() => context.t.loginPage.hashValueNotFound,
  LoginInvalidFormHashException() => context.t.loginPage.failedToGetFormHash,
  LoginMessageNotFoundException() => context.t.loginPage.failedToLoginMessageNodeNotFound,
  LoginIncorrectCaptchaException() => context.t.loginPage.loginResultIncorrectCaptcha,
  LoginInvalidCredentialException() => context.t.loginPage.loginResultIncorrectUsernameOrPassword,
  LoginIncorrectSecurityQuestionException() => context.t.loginPage.loginResultIncorrectQuestionOrAnswer,
  LoginAttemptLimitException() => context.t.loginPage.loginResultTooManyLoginAttempts,
  LoginUserInfoNotFoundException() => context.t.loginPage.loginFailed,
  LoginOtherErrorException() => context.t.loginPage.loginResultOtherErrors,
  _ => context.t.general.failedToLoad,
};

/// Form for user to fill login info.
class LoginForm extends StatefulWidget {
  /// Constructor.
  const LoginForm({
    this.redirectPath,
    this.redirectPathParameters,
    this.redirectExtra,
    this.username,
    this.padding,
    super.key,
  });

  /// The url path to redirect back once login succeed.
  final String? redirectPath;

  /// The path parameters of url to redirect back.
  final Map<String, String>? redirectPathParameters;

  /// The extra object of url to redirect back.
  final Object? redirectExtra;

  /// Optional autofilled username.
  final String? username;

  /// Padding of the scroll view of the form, centers it on wide windows.
  final EdgeInsetsGeometry? padding;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> with LoggerMixin {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController usernameController;
  late final TextEditingController passwordController;
  late final TextEditingController answerController;
  late final TextEditingController verifyCodeController;
  late final CaptchaImageController captchaImageController;

  bool _showPassword = false;

  String _question = _loginQuestions.first;

  LoginField loginField = LoginField.username;

  late final FocusNode loginFieldFocus;
  late final FocusNode passwordFieldFocus;

  Future<void> _login(BuildContext context, LoginField loginField, AuthenticationState state) async {
    if (state.status == AuthenticationStatus.failure) {
      context.read<AuthenticationBloc>().add(AuthenticationFetchLoginHashRequested());
      return;
    }
    if (formKey.currentState == null || !(formKey.currentState!).validate()) {
      return;
    }

    final credential = UserCredential(
      loginField: loginField,
      loginFieldValue: usernameController.text,
      password: passwordController.text,
      // formHash: state.loginHash!.formHash,
      tsdmVerify: verifyCodeController.text,
      securityQuestion: _question == _loginQuestions.first
          ? null
          : SecurityQuestion(questionId: '${_loginQuestions.indexOf(_question)}', answer: answerController.text),
    );

    var times = 10;
    while (context.read<AutoNotificationCubit>().pause('login')) {
      info('login is waiting for auto sync lock... $times');
      times -= 1;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (times <= 0 || !context.mounted) {
        info('auto sync lock timeout or canceled, do not login');
        return;
      }
    }
    context.read<AutoNotificationCubit>().pause('login');
    context.read<AuthenticationBloc>().add(AuthenticationLoginRequested(credential));
  }

  /// Icon and title above the fields.
  Widget _buildHead(BuildContext context) {
    final tr = context.t.loginPage;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        const AppIconTile(Icons.lock_person_outlined, size: 56),
        sizedBoxW12H12,
        Text(
          tr.title,
          textAlign: TextAlign.center,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  /// How the account is identified: chips that wrap on narrow screens, instead of a drop down squeezed into the
  /// prefix of the field.
  Widget _buildLoginFieldChips(BuildContext context) {
    final tr = context.t.loginPage;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final (field, label, icon) in [
          (LoginField.username, tr.loginField.username, Icons.person_outline),
          (LoginField.uid, tr.loginField.uid, Icons.tag),
          (LoginField.email, tr.loginField.email, Icons.alternate_email_outlined),
        ])
          ChoiceChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            selected: loginField == field,
            showCheckmark: false,
            onSelected: (_) {
              setState(() => loginField = field);
              loginFieldFocus.requestFocus();
            },
          ),
      ],
    );
  }

  Widget _buildForm(BuildContext context, AuthenticationState state) {
    // Only allow to press login button when got hash but not logged in.
    final pending = state.status != AuthenticationStatus.gotHash && state.status != AuthenticationStatus.failure;
    final tr = context.t.loginPage;

    // Not a lazy list: every field and the login / retry button stay built, so `validate` checks all the fields
    // (a lazy list skips the ones scrolled away) and the retry button can be reached at any text scale.
    return Form(
      key: formKey,
      child: SingleChildScrollView(
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHead(context),
            const SizedBox(height: 16),
            AppFormSection(
              title: context.t.settingsPage.accountSection.title,
              icon: Icons.account_circle_outlined,
              children: [
                _buildLoginFieldChips(context),
                TextFormField(
                  autofocus: widget.username == null,
                  focusNode: loginFieldFocus,
                  controller: usernameController,
                  decoration: appFieldDecoration(
                    label: switch (loginField) {
                      LoginField.username => tr.loginField.username,
                      LoginField.uid => tr.loginField.uid,
                      LoginField.email => tr.loginField.email,
                    },
                    icon: switch (loginField) {
                      LoginField.username => Icons.person_outline,
                      LoginField.uid => Icons.tag,
                      LoginField.email => Icons.alternate_email_outlined,
                    },
                  ),
                  validator: (v) => v!.trim().isNotEmpty ? null : tr.usernameEmpty,
                ),
                TextFormField(
                  controller: passwordController,
                  focusNode: passwordFieldFocus,
                  decoration: appFieldDecoration(
                    label: tr.password,
                    icon: Icons.password,
                    suffix: Focus(
                      canRequestFocus: false,
                      descendantsAreFocusable: false,
                      child: IconButton(
                        icon: _showPassword ? const Icon(Icons.visibility) : const Icon(Icons.visibility_off),
                        onPressed: () {
                          setState(() {
                            _showPassword = !_showPassword;
                          });
                        },
                      ),
                    ),
                  ),
                  obscureText: !_showPassword,
                  validator: (v) => v!.trim().isNotEmpty ? null : tr.passwordEmpty,
                ),
                // Captcha is only required when the server says so.
                if (state.loginHash?.needCaptcha ?? false)
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: verifyCodeController,
                          decoration: appFieldDecoration(label: tr.verifyCode, icon: Icons.pin),
                          validator: (v) => v!.trim().isNotEmpty ? null : tr.verifyCodeEmpty,
                        ),
                      ),
                      sizedBoxW12H12,
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: CaptchaImage(captchaImageController),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: appSurfaceGap),
            AppFormSection(
              title: tr.securityQuestion,
              icon: Icons.shield_outlined,
              children: [
                InputDecorator(
                  decoration: appFieldDecoration(label: tr.securityQuestion, icon: Icons.question_mark_outlined),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _question,
                      isDense: true,
                      // Long questions are cut with an ellipsis instead of overflowing on narrow phones.
                      isExpanded: true,
                      borderRadius: BorderRadius.circular(appInnerRadius),
                      onChanged: (newValue) {
                        if (newValue == null) {
                          return;
                        }
                        setState(() {
                          _question = newValue;
                        });
                      },
                      items: _loginQuestions.map((value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                TextFormField(
                  controller: answerController,
                  decoration: appFieldDecoration(
                    label: tr.answer,
                    icon: Icons.question_answer_outlined,
                  ).copyWith(enabled: _question != _loginQuestions.first),
                  validator: (v) => _question == _loginQuestions.first || v!.trim().isNotEmpty ? null : tr.answerEmpty,
                ),
              ],
            ),
            if (state.status == AuthenticationStatus.failure) ...[
              const SizedBox(height: appSurfaceGap),
              AppNoticeBanner(message: loginErrorText(context, state.loginException), tone: AppNoticeTone.error),
            ],
            const SizedBox(height: 16),
            DebounceFilledButton(
              shouldDebounce: pending,
              onPressed: () async => _login(context, loginField, state),
              child: Text(state.status == AuthenticationStatus.failure ? context.t.general.retry : tr.login),
            ),
            sizedBoxW12H12,
            Center(
              child: TextButton(
                child: Text(tr.signUpHint, style: const TextStyle(decoration: TextDecoration.underline)),
                onPressed: () async => context.dispatchAsUrl(signUpPage, external: true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    usernameController = TextEditingController(text: widget.username);
    passwordController = TextEditingController();
    answerController = TextEditingController();
    verifyCodeController = TextEditingController();
    loginFieldFocus = FocusNode();
    passwordFieldFocus = FocusNode();
    captchaImageController = CaptchaImageController();

    if (widget.username != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => passwordFieldFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    answerController.dispose();
    verifyCodeController.dispose();
    loginFieldFocus.dispose();
    passwordFieldFocus.dispose();
    captchaImageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthenticationBloc, AuthenticationState>(
      listener: (context, state) async {
        if (state.status == AuthenticationStatus.success) {
          if (widget.redirectPath == null) {
            debug('login success, redirect back');
            Navigator.of(context).pop();
          } else {
            debug(
              'login success, redirect back to: path=${widget.redirectPath} '
              'with parameters=${widget.redirectPathParameters}, '
              'extra=${widget.redirectExtra}',
            );
            context.pushReplacementNamed(
              widget.redirectPath!,
              pathParameters: widget.redirectPathParameters ?? {},
              extra: widget.redirectExtra,
            );
          }
          // Same reason as the pause above: the auto sync resumes only when the holder that paused it resumes.
          context.read<AutoNotificationCubit>().resume('login');
          // Now that there is an account to notify for: the card explaining the notification permission, once.
          askNotificationPermissionAfterLogin();
        } else if (state.status == AuthenticationStatus.failure) {
          // The bloc owns form refresh; listeners must not start duplicate sessions.
          verifyCodeController.clear();
          context.read<AutoNotificationCubit>().resume('login');
        }
      },
      child: BlocBuilder<AuthenticationBloc, AuthenticationState>(builder: _buildForm),
    );
  }
}

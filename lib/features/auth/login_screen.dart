import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// メール＋パスワードのログイン / 新規登録画面。
///
/// 認証されると Supabase セッションが張られ、`AuthGate` がホームへ切り替える。
/// 記事の所有者管理（RLS の `auth.uid()`）に認証ユーザーが必要。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signUp = false; // false=ログイン / true=新規登録
  bool _loading = false;
  String? _message;
  bool _isError = false;

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _isError = true;
        _message = 'メールとパスワードを入力してください';
      });
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_signUp) {
        final res = await auth.signUp(email: email, password: password);
        if (res.session == null) {
          // メール確認が有効な場合はここに来る（確認後にログイン）。
          setState(() {
            _isError = false;
            _message = '確認メールを送信しました。メール内のリンクで確認後、ログインしてください。';
          });
        }
        // session があれば AuthGate が自動でホームへ遷移する。
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (e) {
      setState(() {
        _isError = true;
        _message = e.message;
      });
    } catch (e) {
      setState(() {
        _isError = true;
        _message = '$e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('SyncNews Audio',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_signUp ? 'アカウント作成' : 'ログイン',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'メールアドレス',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'パスワード',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _loading ? null : _submit(),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _message!,
                    style: TextStyle(
                        color: _isError ? Colors.red : Colors.green,
                        fontSize: 13),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_signUp ? '登録してはじめる' : 'ログイン'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                            _signUp = !_signUp;
                            _message = null;
                          }),
                  child: Text(_signUp ? 'アカウントをお持ちの方はログイン' : '新規アカウントを作成'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

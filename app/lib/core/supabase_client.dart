import 'package:supabase_flutter/supabase_flutter.dart';
import 'env.dart';

/// Supabase 초기화 (앱 부팅 시 1회). 초기화는 네트워크 연결을 하지 않으므로
/// 백엔드가 꺼져 있어도 앱은 정상 부팅된다(실호출 시점에만 통신).
Future<void> initSupabase() async {
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabasePublishableKey,
  );
}

SupabaseClient get supabase => Supabase.instance.client;

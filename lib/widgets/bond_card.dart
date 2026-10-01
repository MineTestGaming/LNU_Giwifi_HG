import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/bond_controller.dart';

class BondCard extends StatefulWidget {
  const BondCard(
      {super.key,
      required this.controller,
      required this.locked,
      this.recoveryError});
  final BondController controller;
  final bool locked;
  final String? recoveryError;
  @override
  State<BondCard> createState() => _BondCardState();
}

class _BondCardState extends State<BondCard> {
  Timer? _timer;
  var _ticks = 0;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
      if (++_ticks % 12 == 0 && widget.controller.active) {
        unawaited(_run(widget.controller.verify));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _start() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('创建原生网卡聚合'),
              content: Text(
                  '将绑定以下网卡：\n${widget.controller.selected.map((a) => a.label).join('\n')}\n\n'
                  '此操作需要系统管理员授权，会中断现有连接并生成新的 IP/MAC。'
                  '只有创建前全部在线、创建后聚合接口仍认证在线才保留绑定；失败会恢复原网卡。'
                  '恢复也可能需要管理员授权。macOS 的交换机必须支持并配置 LACP。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('创建聚合'))
              ],
            ));
    if (confirmed == true && mounted) await _run(widget.controller.start);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final locked =
              widget.locked || c.busy || widget.recoveryError != null;
          return Card.outlined(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('多网卡原生聚合',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(c.capability.description),
                    const SizedBox(height: 8),
                    const Text('先检测各网卡，仅已确认认证在线的网卡可勾选。状态有效期 60 秒，创建前会重新验证。'),
                    for (final adapter in c.available)
                      Builder(builder: (context) {
                        final check = c.checks[adapter];
                        final reason = c.capability.reason(adapter);
                        final fresh = check != null &&
                            DateTime.now().difference(check.time) <
                                BondController.evidenceLifetime;
                        final state = !fresh
                            ? '未检测 / 状态已过期'
                            : switch (check.status) {
                                OnlineStatus.online => '已认证在线',
                                OnlineStatus.offline => '未认证',
                                OnlineStatus.unknown => check.error ?? '认证状态未知',
                              };
                        return Row(children: [
                          Expanded(
                              child: CheckboxListTile(
                            key: ValueKey(
                                'bond-member-${adapter.name}-${adapter.address}'),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(adapter.label),
                            subtitle: Text(
                                '$state${reason == null ? '' : '\n$reason'}'),
                            value: c.selected.contains(adapter),
                            onChanged: !locked &&
                                    (c.canSelect(adapter) ||
                                        c.selected.contains(adapter))
                                ? (value) => c.select(adapter, value ?? false)
                                : null,
                          )),
                          IconButton(
                              tooltip: '检测此网卡认证状态',
                              icon: const Icon(Icons.wifi_find),
                              onPressed: locked || c.session != null
                                  ? null
                                  : () => _run(() => c.check(adapter))),
                        ]);
                      }),
                    if (c.available.isEmpty) const Text('暂无网卡，请刷新网卡列表。'),
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      OutlinedButton(
                          onPressed:
                              locked || c.session != null || c.available.isEmpty
                                  ? null
                                  : () => _run(c.checkAll),
                          child: const Text('检测所有网卡')),
                      FilledButton(
                          onPressed: locked ||
                                  c.session != null ||
                                  c.selected.length < 2 ||
                                  c.selected.any((a) => !c.canSelect(a))
                              ? null
                              : _start,
                          child: const Text('启动原生聚合')),
                      if (c.session != null)
                        OutlinedButton(
                            onPressed: c.busy || widget.locked
                                ? null
                                : () => _run(c.stop),
                            child: Text(c.active ? '停止聚合' : '恢复网卡')),
                      if (c.active)
                        OutlinedButton(
                            onPressed: c.busy ? null : () => _run(c.verify),
                            child: const Text('检查聚合状态')),
                    ]),
                    if (c.busy)
                      const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator()),
                    if (c.message != null || widget.recoveryError != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(widget.recoveryError ?? c.message!)),
                    const SizedBox(height: 8),
                    const Text(
                        '原生绑定以单个逻辑网卡工作，成员原先的独立认证不会直接继承。运行期间每 60 秒检查聚合接口，认证失效时尝试撤销绑定。'),
                  ],
                ),
              ));
        },
      );
}

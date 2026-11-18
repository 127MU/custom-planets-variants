import 'package:flutter/material.dart';
import 'expressive_theme.dart';

/// Additional appearance controls shared by the settings and theme presets.
class ThemePreferences extends StatelessWidget {
  const ThemePreferences({
    super.key,
    this.section = 0,
    required this.settings,
    required this.english,
    required this.change,
    required this.savePreset,
    required this.applyPreset,
    required this.renamePreset,
    required this.removePreset,
  });

  final Map<String, dynamic> settings;
  final int section;
  final bool english;
  final ValueChanged<Map<String, dynamic>> change;
  final VoidCallback savePreset;
  final ValueChanged<int> applyPreset, renamePreset, removePreset;
  String t(String zh, String en) => english ? en : zh;

  @override
  Widget build(BuildContext context) {
    double number(String key, double fallback) =>
        (settings[key] as num?)?.toDouble() ?? fallback;
    bool flag(String key, bool fallback) => settings[key] as bool? ?? fallback;
    Widget slider(
      String key,
      String title,
      double fallback,
      double min,
      double max,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title  ${number(key, fallback).toStringAsFixed(2)}'),
        Slider(
          value: number(key, fallback).clamp(min, max),
          min: min,
          max: max,
          onChanged: (value) => change({key: value}),
        ),
      ],
    );
    Widget toggle(
      String key,
      String title,
      String description,
      bool fallback,
    ) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(description),
      value: flag(key, fallback),
      onChanged: (value) => change({key: value}),
    );
    final presets = (settings['themePresets'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (section == 0 || section == 1) ...[
          Text(
            t('背景显示', 'Background display'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, title) in [
                ('cover', t('填充', 'Cover')),
                ('contain', t('完整显示', 'Contain')),
                ('fill', t('拉伸', 'Stretch')),
              ])
                ChoiceChip(
                  label: Text(title),
                  selected: (settings['backgroundFit'] ?? 'cover') == value,
                  onSelected: (_) => change({'backgroundFit': value}),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(t('调整背景画面', 'Adjust background')),
            subtitle: Text(
              t('位置、亮度、模糊和遮罩', 'Position, brightness, blur and overlay'),
            ),
            children: [
              slider('backgroundX', t('水平位置', 'Horizontal position'), 0, -1, 1),
              slider('backgroundY', t('垂直位置', 'Vertical position'), 0, -1, 1),
              slider(
                'backgroundBrightness',
                t('背景亮度', 'Background brightness'),
                1,
                .3,
                1.5,
              ),
              slider('backgroundBlur', t('背景模糊', 'Background blur'), 0, 0, 30),
              slider(
                'backgroundOverlay',
                t('遮罩强度', 'Overlay strength'),
                0,
                0,
                .8,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final (hex, title) in [
                    ('#000000', t('黑色遮罩', 'Black overlay')),
                    ('#FFFFFF', t('白色遮罩', 'White overlay')),
                  ])
                    ChoiceChip(
                      label: Text(title),
                      selected:
                          (settings['backgroundOverlayColor'] ?? '#000000') ==
                          hex,
                      onSelected: (_) =>
                          change({'backgroundOverlayColor': hex}),
                    ),
                  OutlinedButton(
                    onPressed: () async {
                      final hex =
                          (settings['backgroundOverlayColor'] as String? ??
                                  '#000000')
                              .replaceFirst('#', '');
                      final initial = Color(
                        0xff000000 | (int.tryParse(hex, radix: 16) ?? 0),
                      );
                      final selected = await showDialog<Color>(
                        context: context,
                        builder: (_) => CustomThemeColorDialog(
                          initial: initial,
                          english: english,
                        ),
                      );
                      if (selected != null) {
                        change({
                          'backgroundOverlayColor': ExpressiveTheme.hex(
                            selected,
                          ),
                        });
                      }
                    },
                    child: Text(t('自定义遮罩颜色', 'Custom overlay color')),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 32),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(t('视频播放设置', 'Video playback')),
            subtitle: Text(t('控制何时自动暂停', 'Choose when playback pauses')),
            children: [
              toggle(
                'pauseVideoMinimized',
                t('最小化时暂停', 'Pause when minimized'),
                t('恢复窗口后继续播放。', 'Resume when the window is restored.'),
                true,
              ),
              toggle(
                'pauseVideoGame',
                t('游戏运行时暂停', 'Pause while playing'),
                t(
                  '检测到游戏运行时暂停背景视频。',
                  'Pause background video while the game is running.',
                ),
                true,
              ),
            ],
          ),
        ],
        if (section == 0 || section == 2) ...[
          const Divider(height: 32),
          Text(
            t('界面', 'Interface'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          slider('textScale', t('文字大小', 'Text size'), 1, .85, 1.3),
          Wrap(
            spacing: 8,
            children: [
              for (final (value, title) in [
                ('compact', t('紧凑', 'Compact')),
                ('normal', t('标准', 'Normal')),
                ('comfortable', t('宽松', 'Comfortable')),
              ])
                ChoiceChip(
                  label: Text(title),
                  selected: (settings['density'] ?? 'normal') == value,
                  onSelected: (_) => change({'density': value}),
                ),
            ],
          ),
          toggle(
            'animations',
            t('界面动画', 'Interface animations'),
            t('控制主题切换和页面过渡。', 'Controls theme and page transitions.'),
            true,
          ),
          const Divider(height: 32),
          Text(
            t('按时段切换', 'Scheduled theme'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          toggle(
            'scheduledTheme',
            t('自动切换深浅主题', 'Switch light and dark automatically'),
            t(
              '按本机时间切换，关闭后使用手动选择的模式。',
              'Uses local time; manual mode applies when disabled.',
            ),
            false,
          ),
          if (flag('scheduledTheme', false))
            Wrap(
              spacing: 20,
              children: [
                for (final (key, title, fallback) in [
                  ('dayHour', t('白天开始', 'Day starts'), 7),
                  ('nightHour', t('夜间开始', 'Night starts'), 19),
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: settings[key] as int? ?? fallback,
                        items: [
                          for (var hour = 0; hour < 24; hour++)
                            DropdownMenuItem(
                              value: hour,
                              child: Text(
                                '${hour.toString().padLeft(2, '0')}:00',
                              ),
                            ),
                        ],
                        onChanged: (hour) {
                          if (hour != null) change({key: hour});
                        },
                      ),
                    ],
                  ),
              ],
            ),
          if (flag('scheduledTheme', false) &&
              (settings['dayHour'] ?? 7) == (settings['nightHour'] ?? 19))
            Text(t('开始时间相同时保持浅色。', 'Equal start times keep the light theme.')),
        ],
        if (section == 0 || section == 3) ...[
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  t('主题方案', 'Theme presets'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              OutlinedButton.icon(
                onPressed: savePreset,
                icon: const Icon(Icons.add),
                label: Text(t('保存当前方案', 'Save current')),
              ),
            ],
          ),
          if (presets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                t('保存当前配色和背景设置，方便之后切换。', 'Save appearance settings for later.'),
              ),
            ),
          for (var i = 0; i < presets.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text((presets[i] as Map)['name'].toString()),
              onTap: () => applyPreset(i),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: t('应用', 'Apply'),
                    onPressed: () => applyPreset(i),
                    icon: const Icon(Icons.check),
                  ),
                  IconButton(
                    tooltip: t('重命名', 'Rename'),
                    onPressed: () => renamePreset(i),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: t('删除', 'Delete'),
                    onPressed: () => removePreset(i),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

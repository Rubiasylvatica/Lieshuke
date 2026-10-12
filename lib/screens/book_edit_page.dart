import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 新建书表单页 / 编辑书籍资料页：
/// 书名（必填）、作者、国家、出版时间、封面照片、分类。
/// [book] 为空 = 新建；[book] 非空 = 编辑已有书籍。
class BookEditPage extends StatefulWidget {
  const BookEditPage({super.key, required this.repository, this.book});

  final BookRepository repository;
  final Book? book;

  @override
  State<BookEditPage> createState() => _BookEditPageState();
}

class _BookEditPageState extends State<BookEditPage> {
  final _titleCtrl = TextEditingController();
  final _authorCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  final _eraCtrl = TextEditingController();
  final _pathCtrl = TextEditingController();

  final _picker = ImagePicker();
  String? _pickedCoverPath;
  final Set<int> _selectedTagIds = {};
  final Set<String> _selectedPaths = {};
  List<Tag> _tags = [];
  bool _saving = false;

  bool get _isEdit => widget.book != null;

  @override
  void initState() {
    super.initState();
    final b = widget.book;
    if (b != null) {
      // 编辑模式：预填资料与封面
      _titleCtrl.text = b.title;
      _authorCtrl.text = b.author;
      _countryCtrl.text = b.authorCountry;
      _eraCtrl.text = b.authorEra;
      _pickedCoverPath = b.coverPath;
      widget.repository.watchBookTagMap().first.then((map) {
        if (mounted) {
          setState(() {
            _selectedTagIds.addAll(map[b.id] ?? const {});
          });
        }
      });
    }
    widget.repository.watchTags().first.then((tags) {
      if (mounted) {
        setState(() => _tags = tags);
      }
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _countryCtrl.dispose();
    _eraCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1800,
        imageQuality: 90,
      );
      if (file != null) {
        setState(() => _pickedCoverPath = file.path);
      }
    } catch (e) {
      _showSnack('选择照片失败：$e');
    }
  }

  /// 输入路径后回车：加入待用分类路径。
  void _addPath() {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      return;
    }
    setState(() => _selectedPaths.add(path));
    _pathCtrl.clear();
  }

  /// 某标签的完整路径（如「长篇小说 / 中国 / 当代」）。
  String _fullPathOf(int tagId) {
    final byId = {for (final t in _tags) t.id: t};
    final parts = <String>[];
    int? cur = tagId;
    while (cur != null) {
      final tag = byId[cur];
      if (tag == null) {
        break;
      }
      parts.insert(0, tag.name);
      cur = tag.parentId;
    }
    return parts.join(' / ');
  }

  /// 已有末级分类（没有子分类的标签），供快捷选择。
  List<Tag> get _leafTags {
    final parentIds = _tags.map((t) => t.parentId).whereType<int>().toSet();
    return _tags.where((t) => !parentIds.contains(t.id)).toList();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showSnack('请填写书名');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = widget.repository;
      final int bookId;
      if (_isEdit) {
        bookId = widget.book!.id;
        // 封面：换图则先复制到应用私有目录，未换则保持原封面
        String? savedCover;
        if (_pickedCoverPath != null &&
            _pickedCoverPath != widget.book!.coverPath) {
          savedCover = await repo.saveCover(_pickedCoverPath!, bookId);
        }
        await repo.updateBookInfo(
          bookId,
          title: title,
          author: _authorCtrl.text.trim(),
          country: _countryCtrl.text.trim(),
          era: _eraCtrl.text.trim(),
          coverPath: savedCover,
        );
      } else {
        bookId = await repo.createBook(
          title: title,
          author: _authorCtrl.text.trim(),
          country: _countryCtrl.text.trim(),
          era: _eraCtrl.text.trim(),
        );
        // 封面复制到应用私有目录
        if (_pickedCoverPath != null) {
          final saved = await repo.saveCover(_pickedCoverPath!, bookId);
          await repo.updateBookInfo(
            bookId,
            title: title,
            author: _authorCtrl.text.trim(),
            country: _countryCtrl.text.trim(),
            era: _eraCtrl.text.trim(),
            coverPath: saved,
          );
        }
      }
      // 分类：已选标签 + 待建路径
      for (final path in _selectedPaths) {
        final id = await repo.ensureTagPath(path);
        _selectedTagIds.add(id);
      }
      await repo.setBookTags(bookId, _selectedTagIds);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('保存失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑书籍信息' : '新建书')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 封面选择
          Center(
            child: GestureDetector(
              onTap: _pickCover,
              child: Container(
                width: 132,
                height: 198,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _pickedCoverPath == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              size: 32, color: AppColors.textSecondary),
                          SizedBox(height: 8),
                          Text('选择封面照片',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ],
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.file(
                          File(_pickedCoverPath!),
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _field(_titleCtrl, '书名（必填）'),
          const SizedBox(height: 12),
          _field(_authorCtrl, '作者'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _field(_countryCtrl, '国家')),
              const SizedBox(width: 12),
              Expanded(child: _field(_eraCtrl, '出版时间')),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '分类（可多选，用 / 分隔层级，如：长篇小说/中国/当代）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // 路径输入
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  onSubmitted: (_) => _addPath(),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 14),
                  decoration: _inputDecoration('输入分类路径，回车添加'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _addPath,
                child: const Text('添加'),
              ),
            ],
          ),
          // 待建路径展示
          if (_selectedPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _selectedPaths.map((path) => Chip(
                    label: Text(path, style: const TextStyle(fontSize: 12)),
                    onDeleted: () =>
                        setState(() => _selectedPaths.remove(path)),
                    deleteIconColor: AppColors.textSecondary,
                  )).toList(),
            ),
          ],
          // 已有末级分类快捷选择
          if (_leafTags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _leafTags.map((tag) {
                final selected = _selectedTagIds.contains(tag.id);
                return FilterChip(
                  label: Text(
                    _fullPathOf(tag.id),
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: selected,
                  onSelected: (v) => setState(() {
                    v
                        ? _selectedTagIds.add(tag.id)
                        : _selectedTagIds.remove(tag.id);
                  }),
                  backgroundColor: AppColors.surface,
                  selectedColor: AppColors.surfaceHigh,
                  checkmarkColor: AppColors.gold,
                  side: BorderSide(
                    color:
                        selected ? AppColors.gold : AppColors.outline,
                  ),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              foregroundColor: AppColors.textPrimary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(_saving ? '保存中…' : '保存'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      decoration: _inputDecoration(hint),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accentRed),
      ),
    );
  }
}

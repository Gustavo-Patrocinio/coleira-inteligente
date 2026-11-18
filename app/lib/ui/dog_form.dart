import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import 'app_state.dart';

/// Create or edit a dog's profile. Only the name is required; the rest helps reading the
/// numbers (age, size) and the app's wording (he/she).
class DogForm extends StatefulWidget {
  const DogForm({super.key, this.dog, this.onSaved, this.today});

  /// null = new dog.
  final Dog? dog;
  final VoidCallback? onSaved;
  final DateTime Function()? today;

  @override
  State<DogForm> createState() => _DogFormState();
}

class _DogFormState extends State<DogForm> {
  late final _name = TextEditingController(text: widget.dog?.name);
  late final _breed = TextEditingController(text: widget.dog?.breed);
  late final _weight = TextEditingController(
    text: widget.dog?.weightKg == null ? '' : _fmtKg(widget.dog!.weightKg!),
  );
  late String? _sex = widget.dog?.sex;
  late bool? _neutered = widget.dog?.neutered;
  late String? _birth = widget.dog?.birthDate;
  bool _busy = false;
  String? _error;

  static String _fmtKg(double kg) =>
      kg == kg.roundToDouble() ? '${kg.round()}' : '$kg';

  @override
  void dispose() {
    _name.dispose();
    _breed.dispose();
    _weight.dispose();
    super.dispose();
  }

  /// "12,5" and "12.5" both work (Brazilian keyboards type a comma).
  double? get _weightKg =>
      double.tryParse(_weight.text.trim().replaceAll(',', '.'));

  String? _validate() {
    if (_name.text.trim().isEmpty) return 'Give your dog a name.';
    final w = _weight.text.trim();
    if (w.isNotEmpty) {
      final kg = _weightKg;
      if (kg == null || kg <= 0 || kg > 150) {
        return 'Weight in kg, between 0.1 and 150.';
      }
    }
    return null;
  }

  Future<void> _pickBirth() async {
    final today = widget.today?.call() ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_birth ?? '') ?? today,
      firstDate: DateTime(1990),
      lastDate: today,
      helpText: 'Birth date (an estimate is fine)',
    );
    if (picked != null) {
      setState(
        () => _birth =
            '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
      );
    }
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final s = AppScope.of(context);
    final profile = DogProfile(
      name: _name.text.trim(),
      sex: _sex,
      neutered: _neutered,
      breed: _breed.text,
      birthDate: _birth,
      weightKg: _weight.text.trim().isEmpty ? null : _weightKg,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.dog == null) {
        await s.createDog(profile);
      } else {
        await s.updateDog(widget.dog!, profile);
      }
      widget.onSaved?.call();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'Could not save: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final age = _birth == null
        ? null
        : Dog(
            id: 0,
            name: '',
            timezone: '',
            birthDate: _birth,
          ).ageText(widget.today?.call() ?? DateTime.now());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 20),
        Text('Sex', style: text.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<String?>(
          segments: const [
            ButtonSegment(value: 'male', label: Text('Male')),
            ButtonSegment(value: 'female', label: Text('Female')),
            ButtonSegment(value: null, label: Text('Not set')),
          ],
          selected: {_sex},
          onSelectionChanged: (v) => setState(() => _sex = v.first),
        ),
        const SizedBox(height: 16),
        Text('Neutered / spayed', style: text.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<bool?>(
          segments: const [
            ButtonSegment(value: true, label: Text('Yes')),
            ButtonSegment(value: false, label: Text('No')),
            ButtonSegment(value: null, label: Text('Not set')),
          ],
          selected: {_neutered},
          onSelectionChanged: (v) => setState(() => _neutered = v.first),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _breed,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Breed (optional)',
            hintText: 'e.g. Mixed, Labrador',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _weight,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Weight (optional)',
            suffixText: 'kg',
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cake_outlined),
          title: Text(_birth == null ? 'Birth date (optional)' : _birth!),
          subtitle: age == null ? null : Text(age),
          trailing: _birth == null
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _birth = null),
                ),
          onTap: _pickBirth,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(widget.dog == null ? 'Continue' : 'Save'),
        ),
      ],
    );
  }
}

/// Pushed from Profile: add another dog or edit one (with delete).
class DogFormScreen extends StatelessWidget {
  const DogFormScreen({super.key, this.dog});
  final Dog? dog;

  Future<void> _delete(BuildContext context) async {
    final s = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${dog!.name}?'),
        content: const Text(
          'Every recorded minute, trend and alert of this dog is deleted from the server, '
          'and its collars are unpaired. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await s.deleteDog(dog!);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(dog == null ? 'Add a dog' : 'Edit ${dog!.name}'),
        actions: [
          if (dog != null)
            IconButton(
              tooltip: 'Remove this dog',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context),
            ),
        ],
      ),
      body: DogForm(dog: dog, onSaved: () => Navigator.of(context).pop()),
    );
  }
}

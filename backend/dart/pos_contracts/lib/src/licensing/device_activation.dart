/// Result of redeeming a code on this device.
class DeviceActivationResult {
  final bool ok;
  final String? error;

  const DeviceActivationResult._(this.ok, this.error);

  const DeviceActivationResult.success() : this._(true, null);

  const DeviceActivationResult.failed(String error) : this._(false, error);
}

import 'package:bitcoin_base/bitcoin_base.dart';

void main() {
  print(
      "ElectrumRequestScriptHashGetHistory: ${ElectrumRequestScriptHashGetHistory(scriptHash: 'abc').runtimeType}");
  // Check if we can instantiate these or if they exist
  // print("ElectrumRequestBlockchainTransactionGet exists");
  // print("ElectrumRequestBlockchainBlockHeader exists");
}

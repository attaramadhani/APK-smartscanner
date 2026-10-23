import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ai_analysis_service.dart';

class AIAnalysisScreen extends StatefulWidget {
  final String imagePath;
  final String documentName;

  const AIAnalysisScreen({
    super.key,
    required this.imagePath,
    required this.documentName,
  });

  @override
  State<AIAnalysisScreen> createState() => _AIAnalysisScreenState();
}

class _AIAnalysisScreenState extends State<AIAnalysisScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  bool _isOcrLoading = true;
  String _extractedText = "";
  String? _ocrError;

  // Local analysis results
  String _localCategory = "Menganalisis...";
  List<String> _localEmails = [];
  List<String> _localPhones = [];
  List<String> _localDates = [];
  List<String> _localAmounts = [];

  // Gemini API parameters
  String? _apiKey;
  bool _isGeminiLoading = false;
  String? _geminiResult;
  String? _geminiError;

  // Chat Q&A history
  final List<Map<String, String>> _chatHistory = [];
  bool _isChatLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadApiKey();
    _performOcrAndAnalysis();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _apiKeyController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('gemini_api_key');
    if (mounted) {
      setState(() {
        _apiKey = key;
        if (key != null) {
          _apiKeyController.text = key;
        }
      });
    }
  }

  Future<void> _saveApiKey(String key) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', cleanKey);
    
    if (mounted) {
      setState(() {
        _apiKey = cleanKey;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gemini API Key berhasil disimpan!'),
          backgroundColor: Color(0xFF14B8A6),
        ),
      );
    }
  }

  Future<void> _deleteApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gemini_api_key');
    if (mounted) {
      setState(() {
        _apiKey = null;
        _apiKeyController.clear();
        _geminiResult = null;
        _chatHistory.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('API Key dihapus dari perangkat.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _performOcrAndAnalysis() async {
    setState(() {
      _isOcrLoading = true;
      _ocrError = null;
    });

    try {
      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();

      final text = recognizedText.text;
      
      if (mounted) {
        if (text.trim().isEmpty) {
          setState(() {
            _extractedText = "";
            _localCategory = "Dokumen Kosong";
            _isOcrLoading = false;
            _ocrError = "Tidak ada teks yang terdeteksi pada gambar ini. Pastikan gambar cukup terang dan jelas.";
          });
          return;
        }

        final localAnalysis = AIAnalysisService.localHeuristicAnalysis(text);

        setState(() {
          _extractedText = text;
          _localCategory = localAnalysis['category'] as String;
          _localEmails = List<String>.from(localAnalysis['emails'] as List);
          _localPhones = List<String>.from(localAnalysis['phones'] as List);
          _localDates = List<String>.from(localAnalysis['dates'] as List);
          _localAmounts = List<String>.from(localAnalysis['amounts'] as List);
          _isOcrLoading = false;
        });
      }
    } catch (e) {
      print('OCR/Heuristics Analysis Error: $e');
      if (mounted) {
        setState(() {
          _isOcrLoading = false;
          _ocrError = 'Gagal memproses gambar: $e';
        });
      }
    }
  }

  Future<void> _runGeminiAnalysis() async {
    if (_apiKey == null || _apiKey!.isEmpty) return;

    setState(() {
      _isGeminiLoading = true;
      _geminiError = null;
      _geminiResult = null;
    });

    try {
      final analysis = await AIAnalysisService.analyzeWithGemini(_extractedText, _apiKey!);
      if (mounted) {
        setState(() {
          _geminiResult = analysis;
          _isGeminiLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGeminiLoading = false;
          _geminiError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _sendChatMessage() async {
    final question = _chatController.text.trim();
    if (question.isEmpty || _apiKey == null || _isChatLoading) return;

    _chatController.clear();
    setState(() {
      _chatHistory.add({'role': 'user', 'text': question});
      _isChatLoading = true;
    });
    _scrollToBottom();

    try {
      final response = await AIAnalysisService.chatWithGemini(
        docText: _extractedText,
        chatHistory: _chatHistory.sublist(0, _chatHistory.length - 1), // Exclude the current question
        question: question,
        apiKey: _apiKey!,
      );

      if (mounted) {
        setState(() {
          _chatHistory.add({'role': 'model', 'text': response});
          _isChatLoading = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _chatHistory.add({
            'role': 'model',
            'text': '⚠️ Gagal menjawab pertanyaan: ${e.toString().replaceFirst('Exception: ', '')}'
          });
          _isChatLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showApiKeyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.key, color: Color(0xFF2DD4BF)),
            SizedBox(width: 8),
            Text('Konfigurasi Gemini API Key'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Masukkan API Key Gemini untuk mengaktifkan analisis bertenaga LLM dan Q&A Chat interaktif.',
              style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Gemini API Key',
                labelStyle: TextStyle(color: Colors.teal),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF14B8A6)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '💡 Cara mendapatkan Key gratis:\n1. Buka Google AI Studio di browser.\n2. Klik "Get API Key" lalu buat kunci baru.\n3. Salin dan tempel di sini.',
              style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
            ),
          ],
        ),
        actions: [
          if (_apiKey != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _deleteApiKey();
              },
              child: const Text('Hapus Key', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _saveApiKey(_apiKeyController.text);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF14B8A6)),
            child: const Text('Simpan Key', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Analisis Scan AI', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: Icon(
              _apiKey == null ? Icons.vpn_key_outlined : Icons.key,
              color: _apiKey == null ? Colors.white70 : const Color(0xFF2DD4BF),
            ),
            tooltip: 'Gemini API Key',
            onPressed: _showApiKeyDialog,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF14B8A6),
          labelColor: const Color(0xFF2DD4BF),
          unselectedLabelColor: Colors.white70,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'Ekstraksi Lokal'),
            Tab(text: 'Analisis Gemini AI'),
            Tab(text: 'Tanya Dokumen'),
          ],
        ),
      ),
      body: SafeArea(
        child: _isOcrLoading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF14B8A6)),
                    SizedBox(height: 16),
                    Text('Mengekstrak teks dokumen...', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              )
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildLocalExtractionTab(),
                  _buildGeminiAnalysisTab(),
                  _buildChatTab(),
                ],
              ),
      ),
    );
  }

  Widget _buildLocalExtractionTab() {
    if (_ocrError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 48),
              const SizedBox(height: 12),
              Text(
                _ocrError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card with Category
          Card(
            color: const Color(0xFF1E293B),
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F766E).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.description, color: Color(0xFF2DD4BF), size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.documentName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Text('Kategori Terdeteksi: ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                            Text(
                              _localCategory,
                              style: const TextStyle(color: Color(0xFF2DD4BF), fontWeight: FontWeight.bold, fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            'HASIL EKSTRAKSI PINTAR LOKAL (OFFLINE)',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.0),
          ),
          const SizedBox(height: 10),

          // Metadata List Group
          _buildHeuristicItem(Icons.date_range, 'Tanggal Terdeteksi', _localDates),
          _buildHeuristicItem(Icons.mail_outline, 'Alamat Email', _localEmails),
          _buildHeuristicItem(Icons.phone, 'Nomor Telepon', _localPhones),
          _buildHeuristicItem(Icons.payments_outlined, 'Nominal / Nilai Uang', _localAmounts),

          const SizedBox(height: 24),
          const Text(
            'TEKS DOKUMEN HASIL SCAN (RAW OCR)',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.0),
          ),
          const SizedBox(height: 10),

          // Raw OCR box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: SelectableText(
              _extractedText,
              style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeuristicItem(IconData icon, String title, List<String> items) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.symmetric(vertical: 6.0),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF14B8A6), size: 20),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        subtitle: items.isEmpty
            ? const Text('Tidak terdeteksi', style: TextStyle(color: Colors.white30, fontSize: 11, fontStyle: FontStyle.italic))
            : Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: items.map((val) => Chip(
                    backgroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                    labelPadding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    side: const BorderSide(color: Colors.white10),
                    label: Text(val, style: const TextStyle(color: Color(0xFF2DD4BF), fontSize: 10, fontWeight: FontWeight.bold)),
                  )).toList(),
                ),
              ),
      ),
    );
  }

  Widget _buildGeminiAnalysisTab() {
    if (_ocrError != null) {
      return Center(child: Text(_ocrError!, style: const TextStyle(color: Colors.white70)));
    }

    if (_apiKey == null) {
      return _buildApiKeySetupCard();
    }

    if (_isGeminiLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF14B8A6)),
            SizedBox(height: 16),
            Text('Gemini sedang menganalisis dokumen...', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      );
    }

    if (_geminiResult != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ANALISIS DOKUMEN GEMINI AI',
                  style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.0),
                ),
                TextButton.icon(
                  onPressed: _runGeminiAnalysis,
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFF2DD4BF)),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Ulangi', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF14B8A6).withValues(alpha: 0.3)),
              ),
              child: SelectableText(
                _geminiResult!,
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, color: Color(0xFF2DD4BF), size: 48),
          const SizedBox(height: 16),
          const Text(
            'Siap menganalisis dokumen dengan Gemini 1.5 Flash',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          if (_geminiError != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Kesalahan: $_geminiError',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _runGeminiAnalysis,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF14B8A6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.bolt, size: 18),
            label: const Text('Mulai Analisis AI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeySetupCard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: Card(
          color: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.vpn_key, color: Color(0xFF2DD4BF), size: 44),
                const SizedBox(height: 16),
                const Text(
                  'Memerlukan Gemini API Key',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Fitur analisis tingkat lanjut Gemini AI dan Q&A Chat dijalankan langsung dari perangkat menggunakan API Key Anda secara privat dan aman.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _showApiKeyDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14B8A6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Konfigurasi API Key', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChatTab() {
    if (_ocrError != null) {
      return Center(child: Text(_ocrError!, style: const TextStyle(color: Colors.white70)));
    }

    if (_apiKey == null) {
      return _buildApiKeySetupCard();
    }

    return Column(
      children: [
        // Information Banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFF1E293B),
          child: const Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFF2DD4BF), size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tanyakan apa saja tentang isi dokumen ini. AI menjawab berdasarkan teks hasil scan.',
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ],
          ),
        ),

        // Chat Bubble List
        Expanded(
          child: _chatHistory.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forum_outlined, color: Colors.teal.withValues(alpha: 0.4), size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'Belum ada obrolan. Mulai tanyakan sesuatu!',
                        style: TextStyle(color: Colors.white30, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Contoh: "Berapa total pembayarannya?"',
                        style: TextStyle(color: Colors.white24, fontSize: 11, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(16.0),
                  itemCount: _chatHistory.length,
                  itemBuilder: (context, index) {
                    final msg = _chatHistory[index];
                    final isMe = msg['role'] == 'user';

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6.0),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFF14B8A6) : const Color(0xFF1E293B),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(12),
                            topRight: const Radius.circular(12),
                            bottomLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
                            bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                          ),
                          border: isMe ? null : Border.all(color: Colors.white10),
                        ),
                        child: SelectableText(
                          msg['text']!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        if (_isChatLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Color(0xFF14B8A6), strokeWidth: 2),
              ),
            ),
          ),

        // Input Field
        Container(
          padding: const EdgeInsets.all(10.0),
          color: const Color(0xFF0F172A),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(24.0),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: TextField(
                    controller: _chatController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Tanya isi dokumen...',
                      hintStyle: TextStyle(color: Colors.white30),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: (_) => _sendChatMessage(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: const Color(0xFF14B8A6),
                radius: 20,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.white, size: 16),
                  onPressed: _sendChatMessage,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

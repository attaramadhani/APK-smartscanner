import 'dart:convert';
import 'dart:io';

class AIAnalysisService {
  /// Analyzes document text offline using heuristics and regular expressions.
  static Map<String, dynamic> localHeuristicAnalysis(String text) {
    final lowerText = text.toLowerCase();
    
    // 1. Determine Category based on keywords
    String category = 'Dokumen Umum';
    if (lowerText.contains('nik') || 
        (lowerText.contains('provinsi') && lowerText.contains('kartu tanda penduduk')) || 
        lowerText.contains('gol. darah') || 
        lowerText.contains('rt/rw')) {
      category = 'Kartu Identitas (KTP)';
    } else if (lowerText.contains('invoice') || 
               lowerText.contains('tagihan') || 
               lowerText.contains('jatuh tempo') || 
               lowerText.contains('due date') || 
               lowerText.contains('bill to')) {
      category = 'Faktur / Tagihan (Invoice)';
    } else if (lowerText.contains('total') || 
               lowerText.contains('kembalian') || 
               lowerText.contains('kasir') || 
               lowerText.contains('cashier') || 
               lowerText.contains('receipt') || 
               lowerText.contains('tunai') || 
               lowerText.contains('belanja') ||
               lowerText.contains('kwitansi')) {
      category = 'Nota Pembayaran / Struk';
    } else if (lowerText.contains('surat keputusan') || 
               lowerText.contains('kepada yth') || 
               lowerText.contains('perihal') || 
               lowerText.contains('nomor:') || 
               lowerText.contains('berdasarkan') || 
               lowerText.contains('lampiran')) {
      category = 'Surat Resmi';
    }

    // 2. Extract Emails
    final emailRegex = RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', caseSensitive: false);
    final emails = emailRegex.allMatches(text).map((m) => m.group(0)!).toSet().toList();

    // 3. Extract Indonesian Phone Numbers
    final phoneRegex = RegExp(r'(?:\+?62|0)[89]\d{7,11}\b');
    final phones = phoneRegex.allMatches(text).map((m) => m.group(0)!).toSet().toList();

    // 4. Extract Dates
    // Pattern: dd/mm/yyyy or dd-mm-yyyy or written months (e.g. 24 Juni 2026, 12 Dec 2025)
    final dateRegex = RegExp(
      r'\b\d{1,2}[-/\s](?:\d{1,2}|Jan(?:uari)?|Feb(?:ruari)?|Mar(?:et)?|Apr(?:il)?|Mei|Jun(?:i)?|Jul(?:i)?|Agu(?:stus)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Des(?:ember)?|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[-/\s]\d{2,4}\b',
      caseSensitive: false,
    );
    final dates = dateRegex.allMatches(text).map((m) => m.group(0)!).toSet().toList();

    // 5. Extract Monetary Values (Nominal Rupiah/Dollar/Euro)
    final moneyRegex = RegExp(r'\b(?:Rp\.?|IDR|\$|EUR)\s?\d{1,3}(?:\.\d{3})+(?:,\d{2})?\b', caseSensitive: false);
    final amounts = moneyRegex.allMatches(text).map((m) => m.group(0)!).toSet().toList();

    return {
      'category': category,
      'emails': emails,
      'phones': phones,
      'dates': dates,
      'amounts': amounts,
    };
  }

  /// Sends text to Gemini 1.5 Flash for professional summary & entity extraction
  static Future<String> analyzeWithGemini(String text, String apiKey) async {
    final endpoint = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey'
    );

    final prompt = 'Analisis dokumen berikut secara profesional dan berikan output dalam format Markdown yang rapi:\n\n'
        '1. **Tipe Dokumen**: Kategori dokumen ini (misal: Kwitansi Belanja, KTP, Surat Perjanjian, Tagihan Listrik).\n'
        '2. **Ringkasan**: 2-3 kalimat ringkasan singkat mengenai isi dokumen.\n'
        '3. **Rincian Penting**: Tampilkan data penting (seperti nama pihak, tanggal, nomor tagihan, total biaya, alamat) dalam bentuk tabel Markdown atau daftar poin.\n'
        '4. **Analisis Tambahan**: Hal penting lainnya (misal: tanggal jatuh tempo yang mendesak, kejanggalan dokumen, atau instruksi tindak lanjut).\n\n'
        'Berikut adalah teks hasil scan dokumen:\n\n'
        '---\n'
        '$text\n'
        '---';

    final requestBody = {
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ]
    };

    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(requestBody)));
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == HttpStatus.ok) {
        final decoded = jsonDecode(responseBody);
        final candidates = decoded['candidates'] as List<dynamic>;
        if (candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List<dynamic>;
          if (parts.isNotEmpty) {
            return parts[0]['text'] as String;
          }
        }
        throw Exception('Format respon Gemini tidak valid.');
      } else {
        final errorJson = jsonDecode(responseBody);
        final errorMessage = errorJson['error']?['message'] ?? 'Kesalahan tidak diketahui.';
        throw Exception('Status ${response.statusCode}: $errorMessage');
      }
    } catch (e) {
      throw Exception('Gagal menghubungi Gemini API: $e');
    } finally {
      client.close();
    }
  }

  /// Facilitates a Q&A chat turn with Gemini 1.5 Flash based on the document text context.
  ///
  /// [chatHistory] format: List of maps with keys 'role' ('user' or 'model') and 'text'
  static Future<String> chatWithGemini({
    required String docText,
    required List<Map<String, String>> chatHistory,
    required String question,
    required String apiKey,
  }) async {
    final endpoint = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey'
    );

    // Build the request contents array
    final List<Map<String, dynamic>> contents = [];

    // 1. Prepend System context as first user turn
    contents.add({
      'role': 'user',
      'parts': [
        {
          'text': 'Berikut adalah teks dari dokumen yang dipindai:\n\n'
              '=== DOKUMEN ===\n'
              '$docText\n'
              '================\n\n'
              'Jawablah semua pertanyaan pengguna berikutnya berdasarkan isi dokumen di atas. '
              'Gunakan bahasa Indonesia yang santun, jelas, dan profesional. '
              'Jika jawabannya tidak terdapat di dalam dokumen, jelaskan secara jujur bahwa informasi tersebut tidak ditemukan.'
        }
      ]
    });
    // Add dummy model acknowledgment to keep conversation structure aligned
    contents.add({
      'role': 'model',
      'parts': [
        {'text': 'Baik, saya telah membaca dokumen tersebut. Silakan ajukan pertanyaan Anda.'}
      ]
    });

    // 2. Append history
    for (final msg in chatHistory) {
      contents.add({
        'role': msg['role'] == 'user' ? 'user' : 'model',
        'parts': [
          {'text': msg['text']!}
        ]
      });
    }

    // 3. Append current user question
    contents.add({
      'role': 'user',
      'parts': [
        {'text': question}
      ]
    });

    final requestBody = {'contents': contents};

    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(requestBody)));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.ok) {
        final decoded = jsonDecode(responseBody);
        final candidates = decoded['candidates'] as List<dynamic>;
        if (candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List<dynamic>;
          if (parts.isNotEmpty) {
            return parts[0]['text'] as String;
          }
        }
        throw Exception('Format respon Gemini tidak valid.');
      } else {
        final errorJson = jsonDecode(responseBody);
        final errorMessage = errorJson['error']?['message'] ?? 'Kesalahan tidak diketahui.';
        throw Exception('Status ${response.statusCode}: $errorMessage');
      }
    } catch (e) {
      throw Exception('Gagal menghubungi Gemini API: $e');
    } finally {
      client.close();
    }
  }
}

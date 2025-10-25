import 'package:flutter/material.dart';
import 'dart:async'; // For the timer
import 'dart:convert'; // For JSON decoding
import 'package:flutter/services.dart' show rootBundle; // For loading assets
import 'package:provider/provider.dart';
import 'package:collection/collection.dart'; // For list comparison
import 'package:flutter_markdown/flutter_markdown.dart'; // <-- IMPORT THE PACKAGE

// --- 1. DATA MODELS ---

class QuizSection {
  final String title;
  final List<Question> questions;

  QuizSection({required this.title, required this.questions});

  factory QuizSection.fromJson(Map<String, dynamic> json) {
    var questionList = json['questions'] as List<dynamic>;
    List<Question> questions = questionList
        .map((q) => Question.fromJson(q as Map<String, dynamic>))
        .toList();
    return QuizSection(
      title: json['sectionTitle'] as String,
      questions: questions,
    );
  }
}

class SectionInfo {
  final QuizSection section;
  final int localIndex; // 0-based index *within* the section
  final int globalIndex; // index in the flattened list
  final int sectionIndex;

  SectionInfo({
    required this.section,
    required this.localIndex,
    required this.globalIndex,
    required this.sectionIndex,
  });
}

enum QuestionType {
  singleAnswer,
  multipleAnswers,
  reorderParagraphs,
  fillInTheBlanksInput, // RENAMED
  fillInTheBlanksDropdown, // NEW
  fillInTheBlanksDrag, // NEW
}

class BlankOptions {
  final List<String> options;

  BlankOptions({required this.options});

  factory BlankOptions.fromJson(Map<String, dynamic> json) {
    var optionsList = json['options'] as List<dynamic>? ?? [];
    return BlankOptions(
      options: optionsList.map((e) => e as String).toList(),
    );
  }
}

class Question {
  final String id;
  final String text;
  final QuestionType questionType;
  final List<Option> options; // Used for Single/Multi choice AND Drag/Drop word bank
  final String? readingPassage;

  final int? correctOptionIndex;
  final List<int>? correctOptionIndexes;
  final List<int>? correctOrderIndexes; // MODIFIED (was List<String> correctOrder)
  final List<String>? correctAnswers; // Used for all 3 blank types
  final List<BlankOptions>? blanks; // NEW: Used for Dropdown blanks

  Question({
    required this.id,
    required this.text,
    required this.questionType,
    this.options = const [],
    this.readingPassage,
    this.correctOptionIndex,
    this.correctOptionIndexes,
    this.correctOrderIndexes, // MODIFIED
    this.correctAnswers,
    this.blanks, // NEW
  });

  factory Question.fromJson(Map<String, dynamic> json) {
    var optionsList = json['options'] as List? ?? [];
    List<Option> options =
    optionsList.map((i) => Option.fromJson(i as Map<String, dynamic>)).toList();

    // NEW: Parse dropdown blank options
    var blanksList = json['blanks'] as List? ?? [];
    List<BlankOptions> blanks =
    blanksList.map((i) => BlankOptions.fromJson(i as Map<String, dynamic>)).toList();

    QuestionType type;
    switch (json['questionType'] as String?) {
      case 'multipleAnswers':
        type = QuestionType.multipleAnswers;
        break;
      case 'reorderParagraphs':
        type = QuestionType.reorderParagraphs;
        break;
    // --- MODIFIED: Renamed and new types ---
      case 'fillInTheBlanksInput':
        type = QuestionType.fillInTheBlanksInput;
        break;
      case 'fillInTheBlanksDropdown':
        type = QuestionType.fillInTheBlanksDropdown;
        break;
      case 'fillInTheBlanksDrag':
        type = QuestionType.fillInTheBlanksDrag;
        break;
    // --- END MODIFICATION ---
      case 'singleAnswer':
      default:
      // Handle legacy 'fillInTheBlanks' as 'fillInTheBlanksInput'
        if (json['questionType'] == 'fillInTheBlanks') {
          type = QuestionType.fillInTheBlanksInput;
        } else {
          type = QuestionType.singleAnswer;
        }
    }

    return Question(
      id: json['id'] as String,
      text: json['text'] as String,
      questionType: type,
      options: options,
      readingPassage: json['readingPassage'] as String?,
      correctOptionIndex: json['correctOptionIndex'] as int?,
      correctOptionIndexes: (json['correctOptionIndexes'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      // MODIFIED: Read 'correctOrderIndexes'
      correctOrderIndexes: (json['correctOrderIndexes'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      correctAnswers: (json['correctAnswers'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      blanks: blanks.isNotEmpty ? blanks : null, // NEW
    );
  }
}

class Option {
  final String text;
  Option({required this.text});

  factory Option.fromJson(Map<String, dynamic> json) {
    return Option(
      text: json['text'] as String,
    );
  }
}

// --- 2. STATE MANAGEMENT ---

class QuizState extends ChangeNotifier {
  List<QuizSection> _sections = [];
  List<Question> _questions = [];
  final Map<int, SectionInfo> _questionMap = {};

  int _currentQuestionIndex = 0;
  final Map<String, dynamic> _selectedAnswers = {};
  final int _totalTimeInSeconds = 2100; // 35 minutes
  Timer? _timer;
  int timeRemaining = 2100;
  bool _isLoading = true;
  bool _quizFinished = false;

  List<QuizSection> get sections => _sections;
  List<Question> get questions => _questions;
  Question? get currentQuestion =>
      _questions.isNotEmpty ? _questions[_currentQuestionIndex] : null;
  int get currentQuestionIndex => _currentQuestionIndex;
  Map<String, dynamic> get selectedAnswers => _selectedAnswers;
  bool get isLoading => _isLoading;
  bool get quizFinished => _quizFinished;
  int get totalQuestions => _questions.length;

  QuizState() {
    loadQuestions();
  }

  Future<void> loadQuestions() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/questions_1.json');
      final List<dynamic> jsonList = json.decode(jsonString) as List<dynamic>;

      _sections = jsonList
          .map((json) => QuizSection.fromJson(json as Map<String, dynamic>))
          .toList();

      _questions = [];
      _questionMap.clear();

      int globalIndex = 0;
      for (int s = 0; s < _sections.length; s++) {
        for (int q = 0; q < _sections[s].questions.length; q++) {
          final question = _sections[s].questions[q];
          _questions.add(question);
          _questionMap[globalIndex] = SectionInfo(
            section: _sections[s],
            localIndex: q,
            globalIndex: globalIndex,
            sectionIndex: s,
          );
          globalIndex++;
        }
      }

      if (_questions.isEmpty) {
        _questions = _getMockQuestions();
        _sections = [QuizSection(title: "Mock Questions", questions: _questions)];
        _questionMap[0] = SectionInfo(section: _sections[0], localIndex: 0, globalIndex: 0, sectionIndex: 0);
      }
    } catch (e) {
      print("Error loading questions: $e");
      _questions = _getMockQuestions();
      _sections = [QuizSection(title: "Mock Questions", questions: _questions)];
      _questionMap[0] = SectionInfo(section: _sections[0], localIndex: 0, globalIndex: 0, sectionIndex: 0);
    }

    _isLoading = false;
    timeRemaining = _totalTimeInSeconds;
    notifyListeners();
  }

  SectionInfo? get currentSectionInfo {
    return _questionMap[_currentQuestionIndex];
  }

  int getFirstGlobalIndexForSection(int sectionIndex) {
    if (sectionIndex < 0 || sectionIndex >= _sections.length) return 0;
    final entry = _questionMap.entries.firstWhere(
          (entry) => entry.value.sectionIndex == sectionIndex,
      orElse: () => _questionMap.entries.first,
    );
    return entry.value.globalIndex;
  }

  // MODIFIED: Timer logic is now simpler. It just runs.
  void pauseTimer() {
    // _timer?.cancel(); // No longer pause
    notifyListeners();
  }

  void resumeTimer() {
    // _timer?.cancel(); // No longer resume
    // Don't reset timeRemaining
    if (_timer != null && _timer!.isActive) return; // Already running

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timeRemaining > 0) {
        timeRemaining--;
      } else {
        timer.cancel();
        finishQuiz();
      }
      notifyListeners();
    });
  }

  // startTimer just calls resumeTimer
  void startTimer() {
    timeRemaining = _totalTimeInSeconds;
    resumeTimer();
  }

  void updateAnswer(String questionId, dynamic answer) {
    _selectedAnswers[questionId] = answer;
    notifyListeners();
  }

  void nextQuestion() {
    final info = currentSectionInfo;
    if (info == null) return;

    if (info.localIndex < info.section.questions.length - 1) {
      _currentQuestionIndex++;
      notifyListeners();
    }
  }

  void previousQuestion() {
    final info = currentSectionInfo;
    if (info == null) return;

    if (info.localIndex > 0) {
      _currentQuestionIndex--;
      notifyListeners();
    }
  }

  void goToQuestion(int globalIndex) {
    if (globalIndex >= 0 && globalIndex < _questions.length) {
      _currentQuestionIndex = globalIndex;
      notifyListeners();
    }
  }

  void finishQuiz() {
    _timer?.cancel();
    _quizFinished = true;
    notifyListeners();
  }

  void restartQuiz() {
    _sections = [];
    _questions = [];
    _questionMap.clear();
    _currentQuestionIndex = 0;
    _selectedAnswers.clear();
    _quizFinished = false;
    _isLoading = true;
    _timer?.cancel();
    loadQuestions();
  }

  // --- MODIFIED: calculateScore ---
  int calculateScore() {
    int score = 0;
    final ListEquality<dynamic> listEquals = const ListEquality();

    for (var question in _questions) {
      dynamic userAnswer = _selectedAnswers[question.id];
      if (userAnswer == null) continue;

      switch (question.questionType) {
        case QuestionType.singleAnswer:
          if (userAnswer == question.correctOptionIndex) {
            score++;
          }
          break;
        case QuestionType.multipleAnswers:
          final userAnswerList = (userAnswer as List<int>)..sort();
          final correctAnswerList = (question.correctOptionIndexes ?? [])..sort();
          if (listEquals.equals(userAnswerList, correctAnswerList)) {
            score++;
          }
          break;
        case QuestionType.reorderParagraphs:
        // MODIFIED: Compare index lists
        // User answer is List<dynamic> which can contain int? (nulls)
          final userAnswerList = (userAnswer as List<dynamic>)
              .map((e) => e as int?) // Cast each element to int?
              .toList();
          if (listEquals.equals(userAnswerList, question.correctOrderIndexes)) {
            score++;
          }
          break;
        case QuestionType.fillInTheBlanksInput: // RENAMED
        case QuestionType.fillInTheBlanksDropdown: // NEW
        case QuestionType.fillInTheBlanksDrag: // NEW
        // All 3 'blanks' types store a List<String?>
        // We must normalize nulls to empty strings for comparison
          final userAnswerList = (userAnswer as List<dynamic>)
              .map((e) => (e as String? ?? "").trim().toLowerCase())
              .toList();
          final correctAnswerList = (question.correctAnswers ?? [])
              .map((e) => e.trim().toLowerCase())
              .toList();

          if (listEquals.equals(userAnswerList, correctAnswerList)) {
            score++;
          }
          break;
      }
    }
    return score;
  }

  List<Question> _getMockQuestions() {
    return [
      Question(
        id: "q_mock",
        text: "What is the capital of France?",
        questionType: QuestionType.singleAnswer,
        options: [
          Option(text: "Berlin"),
          Option(text: "Madrid"),
          Option(text: "Paris"),
          Option(text: "Rome")
        ],
        correctOptionIndex: 2,
      ),
    ];
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// --- 3. MAIN APP & SCREENS ---

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => QuizState(),
      child: const MockTestApp(),
    ),
  );
}

class MockTestApp extends StatelessWidget {
  const MockTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = ThemeData.light().textTheme;

    return MaterialApp(
      title: 'Mock Test App',
      theme: ThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          surface: Colors.white,
          background: Colors.grey[50],
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[50],
        cardTheme: CardThemeData(
          elevation: 1,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        textTheme: baseTextTheme
            .copyWith(
          displayLarge: baseTextTheme.displayLarge?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.bold,
            color: Colors.teal[800],
          ),
          headlineMedium: baseTextTheme.headlineMedium?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
          headlineSmall: baseTextTheme.headlineSmall?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(0.85),
            height: 1.3,
          ),
          titleLarge: baseTextTheme.titleLarge?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
          titleMedium: baseTextTheme.titleMedium?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
          ),
          bodyLarge: baseTextTheme.bodyLarge?.copyWith(
            fontFamily: 'Inter',
            fontSize: 16,
            color: Colors.black.withOpacity(0.75),
            height: 1.5,
          ),
          labelLarge: baseTextTheme.labelLarge?.copyWith(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
            color: Colors.grey[600],
          ),
        )
            .apply(
          fontFamily: 'Inter',
        ),
      ),
      home: const LandingScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context, listen: false);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.school_outlined,
                      size: 80,
                      color: Colors.teal[600],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome to the Mock Test',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Prepare for your exam by taking this quiz. Good luck!',
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(color: Colors.grey[700]),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    FilledButton.icon(
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Proceed to Test'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 16),
                        textStyle: Theme.of(context).textTheme.titleMedium,
                      ),
                      onPressed: () {
                        if (quizState.quizFinished) {
                          quizState.restartQuiz();
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (context) => const ConsentScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _isAgreed = false;

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Instructions'),
        automaticallyImplyLeading: true,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Before you begin...',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    Text('Please read and agree to the following rules:',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    const RuleTile(
                        icon: Icons.timer,
                        text: 'This is a TIMED test. You will have 35 minutes for the entire test.'),
                    const RuleTile(
                        icon: Icons.account_tree_outlined,
                        text: 'The test is divided into modules. You must complete ONE module before moving to the next.'),
                    const RuleTile(
                        icon: Icons.navigation_outlined,
                        text: 'You can navigate between questions WITHIN a module, but NOT between modules.'),
                    const RuleTile(
                        icon: Icons.pause_circle_outline,
                        text: 'The timer will NOT pause when you return to the module selection screen.'), // MODIFIED RULE
                    const RuleTile(
                        icon: Icons.no_accounts,
                        text:
                        'You must not use any external help (e.g., Google, notes).'),
                    const RuleTile(
                        icon: Icons.do_not_disturb_on,
                        text: 'Once submitted, your answers are FINAL.'),
                    const SizedBox(height: 24),
                    CheckboxListTile(
                      title: const Text(
                          'I understand the RULES and AGREE to not cheat.'),
                      value: _isAgreed,
                      onChanged: (bool? newValue) {
                        setState(() {
                          _isAgreed = newValue ?? false;
                        });
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: Colors.teal,
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: Theme.of(context).textTheme.titleMedium,
                        ),
                        onPressed: _isAgreed
                            ? () {
                          // MODIFIED: Go to ModuleSelectionScreen
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                                builder: (context) => const ModuleSelectionScreen()),
                          );
                          // MODIFIED: Start the timer. DO NOT pause it.
                          quizState.startTimer();
                        }
                            : null,
                        child: const Text('Start Quiz'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RuleTile extends StatelessWidget {
  final IconData icon;
  final String text;
  const RuleTile({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.teal[400]),
          const SizedBox(width: 16),
          Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
        ],
      ),
    );
  }
}

class ModuleSelectionScreen extends StatelessWidget {
  const ModuleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context);

    // --- NEW CHECK ---
    // If the timer runs out, immediately navigate to results.
    if (quizState.quizFinished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const ResultsScreen()),
          );
        }
      });
      // Return a loading indicator while navigating
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // --- END NEW CHECK ---

    Set<String> getAnsweredQuestionIds(QuizSection section) {
      Set<String> answeredIds = {};
      for (var q in section.questions) {
        if (quizState.selectedAnswers.containsKey(q.id)) {
          answeredIds.add(q.id);
        }
      }
      return answeredIds;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Modules'),
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Center(
              child: TimerChip(timeRemaining: quizState.timeRemaining),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: quizState.sections.length,
              itemBuilder: (context, index) {
                final section = quizState.sections[index];
                final answeredIds = getAnsweredQuestionIds(section);
                final bool isComplete = answeredIds.length == section.questions.length;
                final bool isPartiallyComplete = answeredIds.isNotEmpty && !isComplete;

                IconData trailIcon = Icons.radio_button_unchecked;
                Color? trailColor = Colors.grey[400];

                if(isComplete) {
                  trailIcon = Icons.check_circle;
                  trailColor = Colors.green[700];
                } else if (isPartiallyComplete) {
                  trailIcon = Icons.adjust;
                  trailColor = Colors.orange[700];
                }

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8.0),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.teal.shade100,
                      child: Text('${index + 1}', style: TextStyle(color: Colors.teal[800], fontWeight: FontWeight.bold)),
                    ),
                    title: Text(section.title, style: Theme.of(context).textTheme.titleMedium),
                    subtitle: Text('${answeredIds.length} / ${section.questions.length} answered'),
                    trailing: Icon(trailIcon, color: trailColor),
                    onTap: () {
                      final globalIndex = quizState.getFirstGlobalIndexForSection(index);
                      quizState.goToQuestion(globalIndex);
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context) => const QuizScreen()),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                backgroundColor: Colors.green[700],
              ),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Submit Test?'),
                    content: const Text('Are you sure you want to finish and submit the entire test?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          quizState.finishQuiz();
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (context) => const ResultsScreen()),
                          );
                        },
                        child: const Text('Submit'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Submit Entire Test'),
            ),
          )
        ],
      ),
    );
  }
}

class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  late PageController _pageController;
  late QuizState _quizState; // To remove listener on dispose

  @override
  void initState() {
    super.initState();

    _quizState = Provider.of<QuizState>(context, listen: false);

    final sectionInfo = _quizState.currentSectionInfo;
    final initialPage = sectionInfo?.localIndex ?? 0;

    _pageController = PageController(initialPage: initialPage);
    _quizState.addListener(_onStateChange);
  }

  void _onStateChange() {
    if (!mounted) return;

    final state = Provider.of<QuizState>(context, listen: false);

    // --- ADDED: Check if quiz finished ---
    if (state.quizFinished) {
      // If timer ran out, pop back to module screen, which will then redirect to results
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    // --- END ADDED ---

    final sectionInfo = state.currentSectionInfo;
    if (sectionInfo == null) return;

    if (_pageController.hasClients && _pageController.page?.round() != sectionInfo.localIndex) {
      _pageController.animateToPage(
        sectionInfo.localIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _quizState.removeListener(_onStateChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<QuizState>(
      builder: (context, quizState, child) {

        // --- MODIFIED: Check for finish *before* sectionInfo ---
        if (quizState.quizFinished) {
          // This screen is about to be popped, show loading
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        // --- END MODIFICATION ---

        final sectionInfo = quizState.currentSectionInfo;
        if (sectionInfo == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if(mounted) Navigator.of(context).pop();
          });
          return const Scaffold(body: Center(child: Text("Loading section...")));
        }

        final section = sectionInfo.section;
        final firstGlobalIndex = quizState.getFirstGlobalIndexForSection(sectionInfo.sectionIndex);

        return WillPopScope(
          // MODIFIED: On pop, DO NOT pause the timer
          onWillPop: () async {
            // quizState.pauseTimer(); // Timer runs continuously
            return true; // Allow the pop
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(section.title, overflow: TextOverflow.ellipsis, maxLines: 1),
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              elevation: 1,
              shadowColor: Colors.black.withOpacity(0.1),
              // MODIFIED: On back button press, DO NOT pause timer
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  // quizState.pauseTimer(); // Timer runs continuously
                  Navigator.of(context).pop();
                },
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Center(
                    child: TimerChip(timeRemaining: quizState.timeRemaining),
                  ),
                ),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                bool isWide = constraints.maxWidth > 800;
                return Row(
                  children: [
                    if (isWide)
                      Container(
                        width: 250,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border(
                              right: BorderSide(color: Colors.grey[200]!)),
                        ),
                        child: QuestionNavigationPanel(
                          quizState: quizState,
                          currentSection: section,
                          firstGlobalIndex: firstGlobalIndex,
                          isInDrawer: false,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: PageView.builder(
                              controller: _pageController,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: section.questions.length,
                              itemBuilder: (context, localIndex) {
                                final globalIndex = firstGlobalIndex + localIndex;
                                final question = quizState.questions[globalIndex];
                                return QuestionCard(
                                  question: question,
                                  sectionInfo: quizState._questionMap[globalIndex]!,
                                );
                              },
                            ),
                          ),
                          BottomNavBar(pageController: _pageController),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            drawer: LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth <= 800) {
                return Drawer(
                  child: QuestionNavigationPanel(
                    quizState: quizState,
                    currentSection: section,
                    firstGlobalIndex: firstGlobalIndex,
                    isInDrawer: true,
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
          ),
        );
      },
    );
  }
}

class QuestionNavigationPanel extends StatelessWidget {
  final QuizState quizState;
  final QuizSection currentSection;
  final int firstGlobalIndex;
  final bool isInDrawer;

  const QuestionNavigationPanel({
    super.key,
    required this.quizState,
    required this.currentSection,
    required this.firstGlobalIndex,
    this.isInDrawer = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Section Questions',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: currentSection.questions.length,
              itemBuilder: (context, localIndex) {

                final globalIndex = firstGlobalIndex + localIndex;
                final question = currentSection.questions[localIndex];

                final bool isAnswered =
                quizState.selectedAnswers.containsKey(question.id);
                final bool isCurrent = quizState.currentQuestionIndex == globalIndex;

                return InkWell(
                  onTap: () {
                    quizState.goToQuestion(globalIndex);
                    if (isInDrawer) {
                      Navigator.of(context).pop();
                    }
                  },
                  borderRadius: BorderRadius.circular(50),
                  child: CircleAvatar(
                    backgroundColor: isCurrent
                        ? Colors.teal.shade300
                        : (isAnswered
                        ? Colors.teal.shade100
                        : Colors.grey.shade200),
                    child: Text(
                      '${localIndex + 1}',
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.black87,
                        fontWeight:
                        isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class TimerChip extends StatelessWidget {
  final int timeRemaining;
  const TimerChip({super.key, required this.timeRemaining});

  @override
  Widget build(BuildContext context) {
    final int minutes = timeRemaining ~/ 60;
    final int seconds = timeRemaining % 60;
    final bool isLowTime = timeRemaining < 60;

    return Chip(
      avatar: Icon(
        Icons.timer,
        color: isLowTime ? Colors.red[700] : Colors.teal[800],
      ),
      label: Text(
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
        style: TextStyle(
          color: isLowTime ? Colors.red[700] : Colors.teal[800],
          fontWeight: FontWeight.bold,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      backgroundColor: isLowTime ? Colors.red.shade100 : Colors.teal.shade50,
      side: BorderSide.none,
    );
  }
}

class QuestionCard extends StatelessWidget {
  final Question question;
  final SectionInfo sectionInfo;

  const QuestionCard({
    super.key,
    required this.question,
    required this.sectionInfo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    final bool hasReadingPassage =
        question.readingPassage != null && question.readingPassage!.isNotEmpty;

    // --- NEW: Switch for new question types ---
    Widget body;
    switch (question.questionType) {
      case QuestionType.singleAnswer:
        body = _SingleAnswerBody(question: question);
        break;
      case QuestionType.multipleAnswers:
        body = _MultipleAnswerBody(question: question);
        break;
      case QuestionType.reorderParagraphs:
        body = _ReorderParagraphsBody(question: question);
        break;
      case QuestionType.fillInTheBlanksInput:
        body = _FillInTheBlanksInputBody(question: question);
        break;
      case QuestionType.fillInTheBlanksDropdown:
        body = _FillInTheBlanksDropdownBody(question: question);
        break;
      case QuestionType.fillInTheBlanksDrag:
        body = _FillInTheBlanksDragBody(question: question);
        break;
    }
    // --- END NEW ---

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Section: ${sectionInfo.section.title}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.teal[700], fontWeight: FontWeight.bold),
              ),
              Text(
                'Question ${sectionInfo.localIndex + 1} of ${sectionInfo.section.questions.length}',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 16),

              if (hasReadingPassage) ...[
                Text(
                  'Read the text and answer the multiple-choice question by selecting the correct response. Only one response is correct.',
                  style: textTheme.bodyLarge?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 300,
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[50],
                  ),
                  child: SingleChildScrollView(
                    child: MarkdownBody(
                      data: question.readingPassage!,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme)
                          .copyWith(p: textTheme.bodyLarge),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // This is the *actual question*
              // (The [BLANK] markers will be handled by the body widgets)
              if (question.questionType != QuestionType.fillInTheBlanksInput &&
                  question.questionType != QuestionType.fillInTheBlanksDropdown &&
                  question.questionType != QuestionType.fillInTheBlanksDrag)
                MarkdownBody(
                  data: question.text,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: textTheme.headlineSmall,
                    listBullet: textTheme.headlineSmall,
                  ),
                ),

              // For blank questions, the body widget will render the text
              if (question.questionType == QuestionType.fillInTheBlanksInput ||
                  question.questionType == QuestionType.fillInTheBlanksDropdown ||
                  question.questionType == QuestionType.fillInTheBlanksDrag)
                body
              else ...[
                const SizedBox(height: 32),
                body, // The dynamic body (options) is inserted here
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SingleAnswerBody extends StatelessWidget {
  final Question question;
  const _SingleAnswerBody({required this.question});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context);
    final selectedOption = quizState.selectedAnswers[question.id] as int?;

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: question.options.length,
      itemBuilder: (context, index) {
        final option = question.options[index];
        final bool isSelected = selectedOption == index;

        return Card(
          elevation: isSelected ? 2 : 1,
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isSelected ? Colors.teal : Colors.grey.shade300,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: InkWell(
            onTap: () {
              quizState.updateAnswer(question.id, index);
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Radio<int>(
                    value: index,
                    groupValue: selectedOption,
                    onChanged: (value) {
                      quizState.updateAnswer(question.id, value);
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      option.text,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MultipleAnswerBody extends StatelessWidget {
  final Question question;
  const _MultipleAnswerBody({required this.question});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context);
    final selectedOptions =
        (quizState.selectedAnswers[question.id] as List<int>?) ?? [];

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: question.options.length,
      itemBuilder: (context, index) {
        final option = question.options[index];
        final bool isSelected = selectedOptions.contains(index);

        return Card(
          elevation: isSelected ? 2 : 1,
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isSelected ? Colors.teal : Colors.grey.shade300,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: InkWell(
            onTap: () {
              List<int> newSelection = List.from(selectedOptions);
              if (isSelected) {
                newSelection.remove(index);
              } else {
                newSelection.add(index);
              }
              quizState.updateAnswer(question.id, newSelection);
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (value) {
                      List<int> newSelection = List.from(selectedOptions);
                      if (isSelected) {
                        newSelection.remove(index);
                      } else {
                        newSelection.add(index);
                      }
                      quizState.updateAnswer(question.id, newSelection);
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      option.text,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// --- MODIFIED: _ReorderParagraphsBody ---
// This widget is now a full drag-and-drop system
class _ReorderParagraphsBody extends StatefulWidget {
  final Question question;
  const _ReorderParagraphsBody({required this.question});

  @override
  State<_ReorderParagraphsBody> createState() => _ReorderParagraphsBodyState();
}

class _ReorderParagraphsBodyState extends State<_ReorderParagraphsBody> {
  // Holds the index of the option placed in each answer box (null if empty)
  late List<int?> _answerSlots;
  // Holds the original indexes of options available in the bank
  late List<int> _optionBank;

  @override
  void initState() {
    super.initState();
    _initializeState();
  }

  void _initializeState() {
    final quizState = Provider.of<QuizState>(context, listen: false);
    // User answer is List<dynamic> which can contain int? (nulls)
    final savedAnswers = quizState.selectedAnswers[widget.question.id] as List<dynamic>?;

    final int numOptions = widget.question.options.length;

    if (savedAnswers != null) {
      // Load saved state
      _answerSlots = List<int?>.from(savedAnswers.map((e) => e as int?));
      _optionBank = List<int>.generate(numOptions, (i) => i);
      // Remove items from bank that are already in slots
      for (final index in _answerSlots) {
        if (index != null) {
          _optionBank.remove(index);
        }
      }
    } else {
      // Initialize empty state
      _answerSlots = List<int?>.filled(numOptions, null);
      _optionBank = List<int>.generate(numOptions, (i) => i);
      // Save initial empty state
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateState();
      });
    }
  }

  void _updateState() {
    if (!mounted) return;
    final quizState = Provider.of<QuizState>(context, listen: false);
    quizState.updateAnswer(widget.question.id, _answerSlots);
  }

  void _onDropOnAnswerBox(int boxIndex, int optionIndex) {
    setState(() {
      // 1. Get the word currently in the target box (if any)
      final int? oldWordIndex = _answerSlots[boxIndex];

      // 2. Find where the new word came from (either another box or the bank)
      final int sourceBoxIndex = _answerSlots.indexOf(optionIndex); // Use int, default is -1

      // --- MODIFIED: Check for -1 ---
      if (sourceBoxIndex != -1) {
        // Case 1: Dragging from one box to another (swap)
        _answerSlots[sourceBoxIndex] = oldWordIndex;
        _answerSlots[boxIndex] = optionIndex;
      } else {
        // --- END MODIFICATION ---
        // Case 2: Dragging from the bank
        // Add the old word (if any) back to the bank
        if (oldWordIndex != null) {
          if (!_optionBank.contains(oldWordIndex)) {
            _optionBank.add(oldWordIndex);
          }
        }
        // Place new word in the box
        _answerSlots[boxIndex] = optionIndex;
        // Remove new word from the bank
        _optionBank.remove(optionIndex);
      }
    });
    _updateState();
  }

  void _onDropOnBank(int optionIndex) {
    setState(() {
      // Find which box it came from
      final int sourceBoxIndex = _answerSlots.indexOf(optionIndex);
      if (sourceBoxIndex != -1) {
        // Clear the source box
        _answerSlots[sourceBoxIndex] = null;
        // Add the word back to the bank
        if (!_optionBank.contains(optionIndex)) {
          _optionBank.add(optionIndex);
        }
      }
    });
    _updateState();
  }

  void _onReset() {
    setState(() {
      final int numOptions = widget.question.options.length;
      _answerSlots = List<int?>.filled(numOptions, null);
      _optionBank = List<int>.generate(numOptions, (i) => i);
    });
    _updateState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LayoutBuilder(builder: (context, constraints) {
          // Simple responsive layout
          bool isWide = constraints.maxWidth > 600;
          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildDraggableOptions(context)),
                const SizedBox(width: 24),
                Expanded(child: _buildAnswerBoxes(context)),
              ],
            );
          } else {
            return Column(
              children: [
                _buildDraggableOptions(context),
                const SizedBox(height: 24),
                _buildAnswerBoxes(context),
              ],
            );
          }
        }),
        const SizedBox(height: 24),
        // --- ADDED: Reset Button ---
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text("Reset Order"),
          onPressed: _onReset,
        ),
      ],
    );
  }

  Widget _buildDraggableOptions(BuildContext context) {
    return DragTarget<int>(
      builder: (context, candidateData, rejectedData) {
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 100),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!)
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Options", style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: _optionBank.map((optionIndex) {
                  return _DraggableParagraph(
                    optionIndex: optionIndex,
                    text: widget.question.options[optionIndex].text,
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
      onAccept: _onDropOnBank,
    );
  }

  Widget _buildAnswerBoxes(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!)
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Your Answer", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _answerSlots.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, boxIndex) {
              final int? optionIndex = _answerSlots[boxIndex];

              return DragTarget<int>(
                builder: (context, candidateData, rejectedData) {
                  bool isHovering = candidateData.isNotEmpty;
                  if (optionIndex != null) {
                    // Box has a word
                    return _DraggableParagraph(
                      optionIndex: optionIndex,
                      text: widget.question.options[optionIndex].text,
                      isPlaced: true,
                    );
                  }
                  // Box is empty
                  return Container(
                    height: 60,
                    decoration: BoxDecoration(
                        color: isHovering ? Colors.teal.shade50 : Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isHovering ? Colors.teal : Colors.grey[400]!,
                          style: BorderStyle.solid,
                        )
                    ),
                    child: Center(
                      child: Text(
                        'Drop here',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                    ),
                  );
                },
                onAccept: (droppedOptionIndex) {
                  _onDropOnAnswerBox(boxIndex, droppedOptionIndex);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DraggableParagraph extends StatelessWidget {
  final int optionIndex; // The original index (0, 1, 2, 3)
  final String text;
  final bool isPlaced;

  const _DraggableParagraph({
    required this.optionIndex,
    required this.text,
    this.isPlaced = false,
  });

  // Helper to get letter (A, B, C, D)
  String getLetter(int index) {
    return String.fromCharCode('A'.codeUnitAt(0) + index);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Card(
      elevation: isPlaced ? 1 : 2,
      margin: EdgeInsets.zero,
      color: isPlaced ? Colors.teal.shade50 : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.teal[600],
              foregroundColor: Colors.white,
              radius: 12,
              child: Text(getLetter(optionIndex), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
            if (isPlaced) const Icon(Icons.drag_handle, color: Colors.grey),
          ],
        ),
      ),
    );

    return Draggable<int>(
      data: optionIndex, // Drag the original index
      feedback: Material(
        elevation: 4.0,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 350), // Prevent feedback from being too wide
          child: child,
        ),
      ),
      childWhenDragging: isPlaced
          ? Container( // Show dashed box when dragging from an answer slot
        height: 60,
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            // --- THIS IS THE FIX ---
            border: Border.all(
              color: Colors.grey[400]!,
              style: BorderStyle.solid,
            )
          // --- END FIX ---
        ),
      )
          : Opacity(opacity: 0.5, child: child), // Fade out from bank
      child: child,
    );
  }
}

// --- END RE-ORDER WIDGET ---

class _FillInTheBlanksInputBody extends StatefulWidget {
  final Question question;
  const _FillInTheBlanksInputBody({required this.question});

  @override
  State<_FillInTheBlanksInputBody> createState() => _FillInTheBlanksInputBodyState();
}

class _FillInTheBlanksInputBodyState extends State<_FillInTheBlanksInputBody> {
  late List<TextEditingController> _controllers;
  late List<String> _textParts;

  @override
  void initState() {
    super.initState();
    final quizState = Provider.of<QuizState>(context, listen: false);

    _textParts = widget.question.text.split('[BLANK]');

    final savedAnswers = quizState.selectedAnswers[widget.question.id] as List<dynamic>?;
    final int blankCount = _textParts.length - 1;

    _controllers = List.generate(blankCount, (index) {
      final text = (savedAnswers != null && index < savedAnswers.length) ? savedAnswers[index] as String? ?? '' : '';
      final controller = TextEditingController(text: text);

      controller.addListener(() {
        _updateState();
      });
      return controller;
    });

    if (savedAnswers == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if(mounted) _updateState();
      });
    }
  }

  void _updateState() {
    if(!mounted) return;
    final quizState = Provider.of<QuizState>(context, listen: false);
    final answers = _controllers.map((c) => c.text.isNotEmpty ? c.text : null).toList();
    quizState.updateAnswer(widget.question.id, answers);
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = [];
    final textTheme = Theme.of(context).textTheme;

    for (int i = 0; i < _textParts.length; i++) {
      children.add(
          MarkdownBody(
            data: _textParts[i],
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              // --- FONT SIZE LOCATION 1 (MODIFIED) ---
              p: textTheme.titleMedium,
              listBullet: textTheme.titleMedium,
            ),
          )
      );

      if (i < _controllers.length) {
        children.add(
          Container(
            // --- BOX SIZE 1 (MODIFIED) ---
            width: 130,
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: TextField(
              controller: _controllers[i],
              // --- FONT SIZE 1 (MODIFIED) ---
              style: const TextStyle(fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'Answer',
                isDense: true,
              ),
            ),
          ),
        );
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8.0,
      spacing: 8.0,
      children: children,
    );
  }
}

// --- NEW: _FillInTheBlanksDropdownBody ---
class _FillInTheBlanksDropdownBody extends StatefulWidget {
  final Question question;
  const _FillInTheBlanksDropdownBody({required this.question});

  @override
  State<_FillInTheBlanksDropdownBody> createState() =>
      _FillInTheBlanksDropdownBodyState();
}

class _FillInTheBlanksDropdownBodyState
    extends State<_FillInTheBlanksDropdownBody> {
  late List<String?> _selectedValues;
  late List<String> _textParts;
  int _blankCount = 0;

  @override
  void initState() {
    super.initState();
    final quizState = Provider.of<QuizState>(context, listen: false);

    _textParts = widget.question.text.split('[BLANK]');
    _blankCount = _textParts.length - 1;

    final savedAnswers = quizState.selectedAnswers[widget.question.id] as List<dynamic>?;

    _selectedValues = List.generate(_blankCount, (index) {
      return (savedAnswers != null && index < savedAnswers.length)
          ? savedAnswers[index] as String?
          : null;
    });

    if (savedAnswers == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateState();
      });
    }
  }

  void _updateState() {
    if (!mounted) return;
    final quizState = Provider.of<QuizState>(context, listen: false);
    quizState.updateAnswer(widget.question.id, _selectedValues);
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = [];
    final textTheme = Theme.of(context).textTheme;

    for (int i = 0; i < _textParts.length; i++) {
      children.add(
        MarkdownBody(
          data: _textParts[i],
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            // --- FONT SIZE LOCATION 2 (MODIFIED) ---
            p: textTheme.titleLarge,
            listBullet: textTheme.titleMedium,
          ),
        ),
      );

      if (i < _blankCount) {
        // Get options for this specific blank
        final blankOptions = (widget.question.blanks != null &&
            i < widget.question.blanks!.length)
            ? widget.question.blanks![i].options
            : <String>[];

        children.add(
          // --- BOX SIZE 2 (MODIFIED) ---
          SizedBox(
            width: 130,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              // Style the dropdown button to look decent
              decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!)
              ),
              child: DropdownButton<String>(
                value: _selectedValues[i],
                hint: const Text('Select'),
                // Remove the underline
                underline: const SizedBox.shrink(),
                isExpanded: true,
                items: blankOptions.map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    // --- FONT SIZE 2 (MODIFIED) ---
                    child: Text(value, style: const TextStyle(fontSize: 16)),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedValues[i] = newValue;
                  });
                  _updateState();
                },
              ),
            ),
          ),
        );
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8.0,
      spacing: 8.0,
      children: children,
    );
  }
}

// --- NEW: _FillInTheBlanksDragBody ---
class _FillInTheBlanksDragBody extends StatefulWidget {
  final Question question;
  const _FillInTheBlanksDragBody({required this.question});

  @override
  State<_FillInTheBlanksDragBody> createState() =>
      _FillInTheBlanksDragBodyState();
}

class _FillInTheBlanksDragBodyState extends State<_FillInTheBlanksDragBody> {
  late List<String?> _placedWords;
  late List<String> _wordBank;
  late List<String> _textParts;
  int _blankCount = 0;

  @override
  void initState() {
    super.initState();
    final quizState = Provider.of<QuizState>(context, listen: false);
    _textParts = widget.question.text.split('[BLANK]');
    _blankCount = _textParts.length - 1;

    final savedAnswers = quizState.selectedAnswers[widget.question.id] as List<dynamic>?;

    _placedWords = List.generate(_blankCount, (i) => null);
    _wordBank = widget.question.options.map((opt) => opt.text).toList();

    if (savedAnswers != null) {
      for (int i = 0; i < _blankCount; i++) {
        if (i < savedAnswers.length && savedAnswers[i] != null) {
          final word = savedAnswers[i] as String;
          if (_wordBank.contains(word)) {
            _placedWords[i] = word;
            _wordBank.remove(word);
          } else if (widget.question.options.map((e) => e.text).contains(word)) {
            // Word is valid but already placed, just set it
            _placedWords[i] = word;
          }
        }
      }
    }

    if (savedAnswers == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if(mounted) _updateState();
      });
    }
  }

  void _updateState() {
    if (!mounted) return;
    final quizState = Provider.of<QuizState>(context, listen: false);
    quizState.updateAnswer(widget.question.id, _placedWords);
  }

  // Handle dropping a word on a blank
  void _onAccept(int blankIndex, String word) {
    setState(() {
      // If the blank already has a word, return it to the bank
      final String? oldWord = _placedWords[blankIndex];
      if (oldWord != null) {
        if (!_wordBank.contains(oldWord)) {
          _wordBank.add(oldWord);
        }
      }

      // Place the new word
      _placedWords[blankIndex] = word;
      _wordBank.remove(word);
    });
    _updateState();
  }

  // Handle returning a word to the bank
  void _returnToBank(String word) {
    bool wordWasPlaced = false; // <-- FIX: Declared outside setState

    setState(() {
      // Find which blank it came from and clear it
      // bool wordWasPlaced = false; // <-- BUG: Was declared inside setState
      for (int i = 0; i < _placedWords.length; i++) {
        if (_placedWords[i] == word) {
          _placedWords[i] = null;
          wordWasPlaced = true; // Mark that we found it
          break;
        }
      }

      // --- BUG FIX: Only add to bank if it's not already there ---
      if (!_wordBank.contains(word)) {
        _wordBank.add(word);
      }
    });
    // Only update state if a word was actually moved
    if (wordWasPlaced) {
      _updateState();
    }
  }

  Widget _buildWordBank() {
    return DragTarget<String>(
      builder: (context, candidateData, rejectedData) {
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 100),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!)
          ),
          child: Wrap(
            spacing: 8.0,
            runSpacing: 8.0,
            children: _wordBank.map((word) {
              return _DraggableWord(word: word);
            }).toList(),
          ),
        );
      },
      onAccept: (word) {
        _returnToBank(word);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = [];
    final textTheme = Theme.of(context).textTheme;

    for (int i = 0; i < _textParts.length; i++) {
      children.add(
        MarkdownBody(
          data: _textParts[i],
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            // --- FONT SIZE LOCATION 3 (MODIFIED) ---
            p: textTheme.titleLarge,
            listBullet: textTheme.titleMedium,
          ),
        ),
      );

      if (i < _blankCount) {
        children.add(
          _DragTargetBlank(
            word: _placedWords[i],
            onAccept: (word) => _onAccept(i, word),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8.0,
          spacing: 8.0,
          children: children,
        ),
        const SizedBox(height: 32),
        Text('Word Bank', style: textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildWordBank(),
      ],
    );
  }
}

class _DragTargetBlank extends StatelessWidget {
  final String? word;
  final Function(String) onAccept;

  const _DragTargetBlank({this.word, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      builder: (context, candidateData, rejectedData) {
        if (word != null) {
          // If it has a word, make that word draggable *back* to the bank
          return _DraggableWord(word: word!, isPlaced: true);
        }
        // If it's empty, show a blank slot
        return Container(
          // --- BOX SIZE 3 (MODIFIED) ---
          width: 130,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          decoration: BoxDecoration(
              color: candidateData.isNotEmpty ? Colors.teal.shade50 : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: candidateData.isNotEmpty ? Colors.teal : Colors.grey[400]!)
          ),
          child: Center(
            child: Text(
              'Drop here',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ),
        );
      },
      onAccept: onAccept,
    );
  }
}

class _DraggableWord extends StatelessWidget {
  final String word;
  final bool isPlaced;

  const _DraggableWord({required this.word, this.isPlaced = false});

  @override
  Widget build(BuildContext context) {
    Widget child = Chip(
      // --- FONT SIZE 3 (MODIFIED) ---
      label: Text(word, style: const TextStyle(fontSize: 16)),
      backgroundColor: isPlaced ? Colors.teal.shade100 : Colors.white,
      side: BorderSide(color: isPlaced ? Colors.teal : Colors.grey[400]!),
    );

    return Draggable<String>(
      data: word,
      feedback: Material(
        elevation: 4.0,
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
      childWhenDragging: Chip(
        label: Text(word, style: const TextStyle(fontSize: 16)),
        backgroundColor: Colors.grey[200],
      ),
      child: child,
    );
  }
}

class BottomNavBar extends StatelessWidget {
  final PageController pageController;
  const BottomNavBar({super.key, required this.pageController});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context);

    final sectionInfo = quizState.currentSectionInfo;
    if (sectionInfo == null) return const SizedBox.shrink();

    final localIndex = sectionInfo.localIndex;
    final sectionLength = sectionInfo.section.questions.length;
    final bool isLastQuestionInSection = localIndex == sectionLength - 1;
    final bool isLastSection = sectionInfo.sectionIndex == quizState.sections.length - 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            )
          ],
          border: Border(top: BorderSide(color: Colors.grey[200]!))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.arrow_back),
            label: const Text('Previous'),
            onPressed: localIndex == 0
                ? null
                : () {
              quizState.previousQuestion();
            },
          ),

          if (isLastQuestionInSection)
            if (isLastSection)
            // Last question of entire test. Pop to module screen.
              OutlinedButton.icon(
                icon: const Icon(Icons.exit_to_app),
                label: const Text('To Modules'),
                onPressed: () {
                  // quizState.pauseTimer(); // No longer needed
                  Navigator.of(context).pop();
                },
              )
            else
            // Last question of a section, but not the last section.
              FilledButton.icon(
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('Next Module'),
                style: FilledButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.teal[600]
                ),
                onPressed: () {
                  final nextSectionIndex = sectionInfo.sectionIndex + 1;
                  final globalIndex = quizState.getFirstGlobalIndexForSection(nextSectionIndex);
                  quizState.goToQuestion(globalIndex);
                },
              )
          else
          // Standard "Next" button
            OutlinedButton.icon(
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next'),
              onPressed: () {
                quizState.nextQuestion();
              },
            ),
        ],
      ),
    );
  }
}

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context, listen: false);
    final int score = quizState.calculateScore();
    final int total = quizState.totalQuestions;
    final double percentage = total > 0 ? (score / total) * 100 : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Results'),
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Quiz Complete!',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Your Score',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '$score / $total',
                    style: Theme.of(context).textTheme.displayLarge,
                  ),
                  Text(
                    '(${percentage.toStringAsFixed(1)}%)',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.rate_review_outlined),
                      label: const Text('Review Answers'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: Theme.of(context).textTheme.titleMedium,
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (context) => const ReviewScreen()),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Take Quiz Again'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: Theme.of(context).textTheme.titleMedium,
                      ),
                      onPressed: () {
                        Navigator.of(context)
                            .popUntil((route) => route.isFirst);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final quizState = Provider.of<QuizState>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Answers'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16.0),
        itemCount: quizState.totalQuestions,
        itemBuilder: (context, globalIndex) {
          final question = quizState.questions[globalIndex];
          final userAnswer = quizState.selectedAnswers[question.id];
          final sectionInfo = quizState._questionMap[globalIndex]!;

          final bool hasReadingPassage =
              question.readingPassage != null &&
                  question.readingPassage!.isNotEmpty;

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 8.0),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Section: ${sectionInfo.section.title}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Colors.teal[700], fontWeight: FontWeight.bold),
                  ),

                  if (hasReadingPassage) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Reading Passage:',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Container(
                      height: 150,
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[200]!),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey[50],
                      ),
                      child: SingleChildScrollView(
                        child: MarkdownBody(
                          data: question.readingPassage!,
                        ),
                      ),
                    ),
                    const Divider(height: 24),
                  ],

                  MarkdownBody(
                    data: 'Q${sectionInfo.localIndex + 1}: ${question.text}',
                    styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                      p: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildReviewBody(context, question, userAnswer),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- MODIFIED: _buildReviewBody ---
  Widget _buildReviewBody(
      BuildContext context, Question question, dynamic userAnswer) {
    final ListEquality<dynamic> listEquals = const ListEquality();

    switch (question.questionType) {
      case QuestionType.singleAnswer:
        return _ReviewChoiceList(
          question: question,
          selectedIndexes: userAnswer != null ? [userAnswer as int] : [],
          correctIndexes: [question.correctOptionIndex!],
        );

      case QuestionType.multipleAnswers:
        final userAnswerList = (userAnswer as List<int>?) ?? [];
        final correctAnswerList = (question.correctOptionIndexes ?? [])..sort();
        final bool isCorrect = listEquals.equals(userAnswerList..sort(), correctAnswerList);

        return _ReviewChoiceList(
          question: question,
          selectedIndexes: userAnswerList,
          correctIndexes: correctAnswerList,
          isCorrect: isCorrect,
        );

      case QuestionType.reorderParagraphs:
      // MODIFIED: Compare index lists
        final userAnswerIndexes = (userAnswer as List<dynamic>?)
            ?.map((e) => e as int?) // Cast to List<int?>
            .toList() ?? [];
        final correctAnswerIndexes = question.correctOrderIndexes ?? [];
        final bool isCorrect = listEquals.equals(userAnswerIndexes, correctAnswerIndexes);

        // Map indexes back to strings for display, HANDLE NULLS
        final userAnswerStrings = userAnswerIndexes.map((i) {
          if (i == null) return "(Empty)";
          return question.options[i].text;
        }).toList();
        final correctAnswerStrings = correctAnswerIndexes.map((i) => question.options[i].text).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ReviewTile(
              text: 'Your Order:',
              icon: isCorrect ? Icons.check_circle : Icons.cancel,
              color: isCorrect ? Colors.green[700] : Colors.red[700],
            ),
            ...userAnswerStrings.map((e) => Padding(
              padding: const EdgeInsets.only(left: 40.0, top: 4),
              child: Text('• $e'),
            )),
            if (!isCorrect) ...[
              const SizedBox(height: 16),
              _ReviewTile(
                text: 'Correct Order:',
                icon: Icons.check_circle_outline,
                color: Colors.green[700],
              ),
              ...correctAnswerStrings.map((e) => Padding(
                padding: const EdgeInsets.only(left: 40.0, top: 4),
                child: Text('• $e'),
              )),
            ]
          ],
        );

      case QuestionType.fillInTheBlanksInput:
      case QuestionType.fillInTheBlanksDropdown:
      case QuestionType.fillInTheBlanksDrag:
      // All 3 use the same review logic
        final userAnswerList = (userAnswer as List<dynamic>?) ?? [];
        final correctAnswerList = (question.correctAnswers ?? []);

        final normalizedUser = userAnswerList.map((e) => (e as String? ?? "").trim().toLowerCase()).toList();
        final normalizedCorrect = correctAnswerList.map((e) => e.trim().toLowerCase()).toList();
        final bool isCorrect = listEquals.equals(normalizedUser, normalizedCorrect);

        // Format user answers to show "Empty" for null/empty
        final displayUserAnswers = userAnswerList.map((e) {
          final str = (e as String? ?? "");
          return str.isEmpty ? "(Empty)" : str;
        }).join(", ");

        return Column(
          children: [
            _ReviewTile(
              text: 'Your Answers: $displayUserAnswers',
              icon: isCorrect ? Icons.check_circle : Icons.cancel,
              color: isCorrect ? Colors.green[700] : Colors.red[700],
            ),
            if (!isCorrect)
              _ReviewTile(
                text: 'Correct Answers: ${correctAnswerList.join(", ")}',
                icon: Icons.check_circle_outline,
                color: Colors.green[700],
              ),
          ],
        );
    }
  }
}

class _ReviewChoiceList extends StatelessWidget {
  final Question question;
  final List<int> selectedIndexes;
  final List<int> correctIndexes;
  final bool? isCorrect;

  const _ReviewChoiceList({
    required this.question,
    required this.selectedIndexes,
    required this.correctIndexes,
    this.isCorrect,
  });

  @override
  Widget build(BuildContext context) {
    if (isCorrect != null) {
      return Column(
        children: [
          _ReviewTile(
            text: 'Your selections were ${isCorrect! ? "Correct" : "Incorrect"}',
            icon: isCorrect! ? Icons.check_circle : Icons.cancel,
            color: isCorrect! ? Colors.green[700] : Colors.red[700],
          ),
          const Divider(height: 24),
          ..._buildAllOptions(context),
        ],
      );
    }

    return Column(
      children: _buildAllOptions(context),
    );
  }

  List<Widget> _buildAllOptions(BuildContext context) {
    return question.options.map((option) {
      final int index = question.options.indexOf(option);
      final bool isSelected = selectedIndexes.contains(index);
      final bool isCorrect = correctIndexes.contains(index);

      IconData? icon;
      Color? color;
      String? subtitle;

      if (isCorrect && isSelected) {
        icon = Icons.check_circle;
        color = Colors.green[700];
        subtitle = 'Correct & Selected';
      } else if (isCorrect && !isSelected) {
        icon = Icons.check_circle_outline;
        color = Colors.green[700];
        subtitle = 'Correct Answer';
      } else if (!isCorrect && isSelected) {
        icon = Icons.cancel;
        color = Colors.red[700];
        subtitle = 'Incorrectly Selected';
      }

      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(option.text, style: TextStyle(
          fontWeight: (isCorrect || isSelected) ? FontWeight.bold : FontWeight.normal,
        )),
        subtitle: subtitle != null ? Text(subtitle, style: TextStyle(color: color)) : null,
      );
    }).toList();
  }
}

class _ReviewTile extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;
  const _ReviewTile({required this.text, required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(text),
    );
  }
}
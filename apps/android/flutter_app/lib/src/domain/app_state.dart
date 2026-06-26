enum AgeBand { fourToFive, sixToEight, nineToTwelve }

enum AppStep { onboarding, parentHome, childMode }

enum ConversationStatus { idle, listening, thinking, speaking }

class ModelRecommendation {
  const ModelRecommendation({
    required this.modelId,
    required this.displayName,
    required this.installed,
    this.runtimeMode = 'custom',
  });

  final String modelId;
  final String displayName;
  final bool installed;
  final String runtimeMode;

  ModelRecommendation copyWith({bool? installed}) => ModelRecommendation(
    modelId: modelId,
    displayName: displayName,
    installed: installed ?? this.installed,
    runtimeMode: runtimeMode,
  );
}

class AppState {
  const AppState({
    this.step = AppStep.onboarding,
    this.ageBand,
    this.recommendation,
    this.characterName = 'Teddy',
    this.conversationStatus = ConversationStatus.idle,
  });

  final AppStep step;
  final AgeBand? ageBand;
  final ModelRecommendation? recommendation;
  final String characterName;
  final ConversationStatus conversationStatus;

  bool get onboardingReady =>
      ageBand != null && recommendation?.installed == true;

  AppState copyWith({
    AppStep? step,
    AgeBand? ageBand,
    ModelRecommendation? recommendation,
    String? characterName,
    ConversationStatus? conversationStatus,
  }) => AppState(
    step: step ?? this.step,
    ageBand: ageBand ?? this.ageBand,
    recommendation: recommendation ?? this.recommendation,
    characterName: characterName ?? this.characterName,
    conversationStatus: conversationStatus ?? this.conversationStatus,
  );
}

sealed class AppEvent {
  const AppEvent();
}

class AgeSelected extends AppEvent {
  const AgeSelected(this.ageBand);
  final AgeBand ageBand;
}

class DeviceAssessed extends AppEvent {
  const DeviceAssessed(this.recommendation);
  final ModelRecommendation recommendation;
}

class CharacterNamed extends AppEvent {
  const CharacterNamed(this.name);
  final String name;
}

class ModelInstalled extends AppEvent {
  const ModelInstalled();
}

class OnboardingCompleted extends AppEvent {
  const OnboardingCompleted();
}

class ChildModeStarted extends AppEvent {
  const ChildModeStarted();
}

class TalkStarted extends AppEvent {
  const TalkStarted();
}

class TranscriptAccepted extends AppEvent {
  const TranscriptAccepted();
}

class ResponseReady extends AppEvent {
  const ResponseReady();
}

class PlaybackCompleted extends AppEvent {
  const PlaybackCompleted();
}

class ConversationFailed extends AppEvent {
  const ConversationFailed();
}

class ChildModeExited extends AppEvent {
  const ChildModeExited({required this.parentAuthorized});
  final bool parentAuthorized;
}

class AppTransition {
  const AppTransition(this.state, {this.error});
  final AppState state;
  final String? error;
}

abstract final class AppReducer {
  static AppTransition reduce(AppState state, AppEvent event) {
    switch (event) {
      case AgeSelected():
        return AppTransition(state.copyWith(ageBand: event.ageBand));
      case DeviceAssessed():
        return AppTransition(
          state.copyWith(recommendation: event.recommendation),
        );
      case CharacterNamed():
        final name = event.name.trim();
        if (name.length < 2 ||
            name.length > 40 ||
            !RegExp(r"^[\p{L}\p{N} '\-.&]+$", unicode: true).hasMatch(name)) {
          return AppTransition(state, error: 'Enter a valid character name.');
        }
        return AppTransition(state.copyWith(characterName: name));
      case ModelInstalled():
        final recommendation = state.recommendation;
        if (recommendation == null) {
          return AppTransition(state, error: 'Assess this device first.');
        }
        return AppTransition(
          state.copyWith(
            recommendation: recommendation.copyWith(installed: true),
          ),
        );
      case OnboardingCompleted():
        if (!state.onboardingReady) {
          return AppTransition(
            state,
            error: 'Select an age band and install the local model.',
          );
        }
        return AppTransition(state.copyWith(step: AppStep.parentHome));
      case ChildModeStarted():
        if (state.step != AppStep.parentHome) {
          return AppTransition(state, error: 'Parent setup is required.');
        }
        return AppTransition(
          state.copyWith(
            step: AppStep.childMode,
            conversationStatus: ConversationStatus.idle,
          ),
        );
      case TalkStarted():
        return _conversationTransition(
          state,
          ConversationStatus.idle,
          ConversationStatus.listening,
        );
      case TranscriptAccepted():
        return _conversationTransition(
          state,
          ConversationStatus.listening,
          ConversationStatus.thinking,
        );
      case ResponseReady():
        return _conversationTransition(
          state,
          ConversationStatus.thinking,
          ConversationStatus.speaking,
        );
      case PlaybackCompleted():
        if (state.step != AppStep.childMode ||
            state.conversationStatus == ConversationStatus.idle) {
          return AppTransition(state);
        }
        return _conversationTransition(
          state,
          ConversationStatus.speaking,
          ConversationStatus.idle,
        );
      case ConversationFailed():
        if (state.step != AppStep.childMode) {
          return AppTransition(state);
        }
        return AppTransition(
          state.copyWith(conversationStatus: ConversationStatus.idle),
        );
      case ChildModeExited():
        if (!event.parentAuthorized) {
          return AppTransition(state, error: 'Parent authorization required.');
        }
        return AppTransition(
          state.copyWith(
            step: AppStep.parentHome,
            conversationStatus: ConversationStatus.idle,
          ),
        );
    }
  }

  static AppTransition _conversationTransition(
    AppState state,
    ConversationStatus expected,
    ConversationStatus next,
  ) {
    if (state.step != AppStep.childMode ||
        state.conversationStatus != expected) {
      return AppTransition(state, error: 'Conversation event out of order.');
    }
    return AppTransition(state.copyWith(conversationStatus: next));
  }
}

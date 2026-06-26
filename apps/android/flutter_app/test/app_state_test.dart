import 'package:flutter_test/flutter_test.dart';
import 'package:plushpal_ui/src/domain/app_state.dart';

void main() {
  test('onboarding fails closed until age and verified model are present', () {
    const initial = AppState();
    expect(
      AppReducer.reduce(initial, const OnboardingCompleted()).error,
      isNotNull,
    );
    var state = AppReducer.reduce(
      initial,
      const AgeSelected(AgeBand.sixToEight),
    ).state;
    state = AppReducer.reduce(
      state,
      const DeviceAssessed(
        ModelRecommendation(
          modelId: 'small',
          displayName: 'Small',
          installed: false,
        ),
      ),
    ).state;
    expect(
      AppReducer.reduce(state, const OnboardingCompleted()).error,
      isNotNull,
    );
    state = AppReducer.reduce(state, const ModelInstalled()).state;
    expect(
      AppReducer.reduce(state, const OnboardingCompleted()).state.step,
      AppStep.parentHome,
    );
  });

  test('conversation events must remain ordered', () {
    const child = AppState(
      step: AppStep.childMode,
      conversationStatus: ConversationStatus.idle,
    );
    expect(AppReducer.reduce(child, const ResponseReady()).error, isNotNull);
    var state = AppReducer.reduce(child, const TalkStarted()).state;
    state = AppReducer.reduce(state, const TranscriptAccepted()).state;
    state = AppReducer.reduce(state, const ResponseReady()).state;
    state = AppReducer.reduce(state, const PlaybackCompleted()).state;
    expect(state.conversationStatus, ConversationStatus.idle);
  });

  test('child mode cannot exit without parent authorization', () {
    const child = AppState(step: AppStep.childMode);
    final denied = AppReducer.reduce(
      child,
      const ChildModeExited(parentAuthorized: false),
    );
    expect(denied.error, isNotNull);
    expect(denied.state.step, AppStep.childMode);
  });

  test('character name is bounded and allowlisted', () {
    const initial = AppState();
    expect(
      AppReducer.reduce(initial, const CharacterNamed('T')).error,
      isNotNull,
    );
    final named = AppReducer.reduce(
      initial,
      const CharacterNamed('Teddy Bear'),
    );
    expect(named.error, isNull);
    expect(named.state.characterName, 'Teddy Bear');
  });
}

#import "HelmDocumentCloseReply.h"
#import <objc/message.h>
void HelmReplyToDocumentClose(id delegate, SEL selector, NSDocument *document,
                              BOOL shouldClose, void *context) {
  if (delegate && selector && [delegate respondsToSelector:selector]) {
    ((void (*)(id, SEL, NSDocument *, BOOL, void *))objc_msgSend)(
        delegate, selector, document, shouldClose, context);
  }
}

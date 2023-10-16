//
//  RNIContextMenuButton.swift
//  IosContextMenuExample
//
//  Created by Dominic Go on 10/28/20.
//  Copyright © 2020 Facebook. All rights reserved.
//

import UIKit;
import ExpoModulesCore;
import ReactNativeIosUtilities;


public class RNIContextMenuButton:
  ExpoView, RNIMenuElementEventsNotifiable, UIGestureRecognizerDelegate,
  RNINavigationEventsNotifiable, RNICleanable, RNIJSComponentWillUnmountNotifiable {

  // MARK: - Properties
  // ------------------
  
  var button: UIButton!;

  private var deferredElementCompletionMap:
    [String: RNIDeferredMenuElement.CompletionHandler] = [:];
    
  weak var viewController: RNINavigationEventsReportingViewController?;
  
  // MARK: - Properties - Flags
  // --------------------------
  
  var isContextMenuVisible = false;
  var didPressMenuItem = false;
  
  private var didTriggerCleanup = false;
  
  /// Whether or not the current view was successfully added as child VC
  private var didAttachToParentVC = false;
  
  // MARK: - Properties - Props
  // --------------------------
  
  private(set) public var menuConfig: RNIMenuItem?;
  public var menuConfigRaw: Dictionary<String, Any>? {
    willSet {
      guard let newValue = newValue,
            newValue.count > 0,
            
            let rootMenuConfig = RNIMenuItem(dictionary: newValue)
      else { return };
      
      self.menuConfig = rootMenuConfig;
      rootMenuConfig.delegate = self;
      
      // cleanup `deferredElementCompletionMap`
      self.cleanupOrphanedDeferredElements(currentMenuConfig: rootMenuConfig);
      self.updateContextMenu(with: rootMenuConfig);
    }
  };
  
  public var isMenuPrimaryAction: Bool = false {
    didSet {
      guard #available(iOS 14.0, *),
            self.isMenuPrimaryAction != oldValue
      else { return };
      
      self.button.showsMenuAsPrimaryAction = self.isMenuPrimaryAction;
    }
  };
  
  public var isContextMenuEnabled: Bool = true {
    didSet {
      guard #available(iOS 14.0, *),
            self.isContextMenuEnabled != oldValue
      else { return };
      
      self.button.isContextMenuInteractionEnabled = self.isContextMenuEnabled;
    }
  };
  
  private(set) public var internalCleanupMode: RNICleanupMode = .automatic;
  public var internalCleanupModeRaw: String? {
    willSet {
      guard let newValue = newValue,
            let cleanupMode = RNICleanupMode(rawValue: newValue)
      else { return };
      
      self.internalCleanupMode = cleanupMode;
    }
  };
  
  // MARK: - Properties - Props - Events
  // -----------------------------------

  public var onMenuWillShow   = EventDispatcher("onMenuWillShow");
  public var onMenuWillHide   = EventDispatcher("onMenuWillHide");
  public var onMenuWillCancel = EventDispatcher("onMenuWillCancel");
  
  public var onMenuDidShow   = EventDispatcher("onMenuDidShow");
  public var onMenuDidHide   = EventDispatcher("onMenuDidHide");
  public var onMenuDidCancel = EventDispatcher("onMenuDidCancel");
  
  public var onPressMenuItem = EventDispatcher("onPressMenuItem");
  
  public var onRequestDeferredElement =
    EventDispatcher("onRequestDeferredElement");
    
  // MARK: - Computed Properties
  // ---------------------------
  
  private var shouldEnableAttachToParentVC: Bool {
    self.cleanupMode == .viewController
  };
  
  private var shouldEnableCleanup: Bool {
    self.cleanupMode != .disabled
  };
  
  var cleanupMode: RNICleanupMode {
    get {
      switch self.internalCleanupMode {
        case .automatic: return .reactComponentWillUnmount;
        default: return self.internalCleanupMode;
      };
    }
  };
  
  // MARK: Init + Lifecycle
  // ----------------------
  
  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext);
    
    self.setupButton();
    self.setupAddContextMenuInteraction();
  };
  
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented");
  };
  
  
  public override func reactSetFrame(_ frame: CGRect) {
    super.reactSetFrame(frame);
  };
  
  // MARK: - View Lifecycle
  // ----------------------
  
  public override func didMoveToWindow() {
    if self.window == nil,
       !self.didAttachToParentVC {
      
      // not using UINavigationController... manual cleanup
      self.cleanup();
      
    } else if !self.didAttachToParentVC {
      
      // setup - might be using UINavigationController, attach as child vc
      self.attachToParentVC();
    };
  };
  
  public override func insertReactSubview(_ subview: UIView!, at atIndex: Int) {
    self.button.insertSubview(subview, at: atIndex);
  };
  
  public override func removeReactSubview(_ subview: UIView!) {
    guard let subviewToRemove = self.button.viewWithTag(subview.tag) else { return };
    subviewToRemove.removeFromSuperview();
  };
  
  // MARK: - Functions
  // -----------------
  
  func setupButton(){
    let button = UIButton();
    self.button = button;
    
    self.addSubview(button);
    button.translatesAutoresizingMaskIntoConstraints = false;
    
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(
        equalTo: self.leadingAnchor
      ),
      button.trailingAnchor.constraint(
        equalTo: self.trailingAnchor
      ),
      button.topAnchor.constraint(
        equalTo: self.topAnchor
      ),
      button.bottomAnchor.constraint(
        equalTo: self.bottomAnchor
      ),
    ]);
  };
  
  /// Add a context menu interaction to button
  func setupAddContextMenuInteraction(){
    self.button.isEnabled = true;
    self.button.isUserInteractionEnabled = true;
    
    let gesture = UIGestureRecognizer();
    gesture.cancelsTouchesInView = true;
    gesture.delegate = self;
    
    // self.addAction( UIAction(title: ""){ action in
    //   print("menuActionTriggered");
    //   // TODO: wip
    // }, for: .menuActionTriggered);
  };
  
  func updateContextMenu(with menuConfig: RNIMenuItem){
    guard #available(iOS 14.0, *),
          let interaction = self.button.contextMenuInteraction
    else { return };
    
    let menu = menuConfig.createMenu(
      actionItemHandler: { [unowned self] in
        self.handleOnPressMenuActionItem(dict: $0, action: $1);
        
      }, deferredElementHandler: {  [unowned self] in
        // B. deferred element is requesting for items to load...
        self.handleOnDeferredElementRequest(
          deferredID: $0, completion: $1
        );
      }
    );
    
    if self.isContextMenuVisible {
      // context menu is open, update the menu items
      interaction.updateVisibleMenu { _ in
        return menu;
      };
      
    } else {
      self.button.menu = menu;
    };
  };
  
  func handleOnPressMenuActionItem(
    dict: [String: Any],
    action: UIAction
  ){
    self.didPressMenuItem = true;
    self.onPressMenuItem.callAsFunction(dict);
  };
  
  func handleOnDeferredElementRequest(
    deferredID: String,
    completion: @escaping RNIDeferredMenuElement.CompletionHandler
  ){
    // register completion handler
    self.deferredElementCompletionMap[deferredID] = completion;
    
    // notify js that a deferred element needs to be loaded
    self.onRequestDeferredElement.callAsFunction([
      "deferredID": deferredID,
    ]);
  };
  
  func cleanupOrphanedDeferredElements(currentMenuConfig: RNIMenuItem) {
    guard self.deferredElementCompletionMap.count > 0
    else { return };
    
    let currentDeferredElements = RNIMenuElement.recursivelyGetAllElements(
      from: currentMenuConfig,
      ofType: RNIDeferredMenuElement.self
    );
      
    // get the deferred elements that are not in the new config
    let orphanedKeys = self.deferredElementCompletionMap.keys.filter { deferredID in
      !currentDeferredElements.contains {
        $0.deferredID == deferredID
      };
    };
    
    // cleanup
    orphanedKeys.forEach {
      self.deferredElementCompletionMap.removeValue(forKey: $0);
    };
  };
  
  func attachToParentVC(){
    guard self.shouldEnableAttachToParentVC,
          !self.didAttachToParentVC,
          
          // find the nearest parent view controller
          let parentVC = RNIHelpers.getParent(
            responder: self,
            type: UIViewController.self
          )
    else { return };
    
    self.didAttachToParentVC = true;
    
    let childVC = RNINavigationEventsReportingViewController();
    childVC.view = self;
    childVC.delegate = self;
    childVC.parentVC = parentVC;
    
    self.viewController = childVC;

    parentVC.addChild(childVC);
    childVC.didMove(toParent: parentVC);
  };
  
  func detachFromParentVC(){
    guard !self.didAttachToParentVC,
          let childVC = self.viewController
    else { return };
    
    childVC.willMove(toParent: nil);
    childVC.removeFromParent();
  };
  
  // MARK: - Functions - View Module Commands
  // ----------------------------------------
  
  public func dismissMenu(){
    guard #available(iOS 14.0, *) else { return };
    self.button.contextMenuInteraction?.dismissMenu();
  };
  
  public func provideDeferredElements(id deferredID: String, menuElements: [RNIMenuElement]){
    if let completion = self.deferredElementCompletionMap[deferredID] {

      // create + add menu elements
      completion( menuElements.compactMap { menuElement in
        menuElement.createMenuElement(
          actionItemHandler: { [unowned self] in
            self.handleOnPressMenuActionItem(dict: $0, action: $1);
            
          }, deferredElementHandler: { [unowned self] in
            self.handleOnDeferredElementRequest(deferredID: $0, completion: $1);
          }
        );
      });
      
      // cleanup
      self.deferredElementCompletionMap.removeValue(forKey: deferredID);
    };
  };
  
  // MARK: - RNIMenuElementEventsNotifiable
  // --------------------------------------
  
  public func notifyOnMenuElementUpdateRequest(for element: RNIMenuElement) {
    guard let menuConfig = self.menuConfig else { return };
    self.updateContextMenu(with: menuConfig);
  };
  
  // MARK: - UIGestureRecognizerDelegate
  // -----------------------------------
  
  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    return true;
  };
  
  // MARK: - RNINavigationEventsNotifiable
  // -------------------------------------
  
  public func notifyViewControllerDidPop(sender: RNINavigationEventsReportingViewController) {
    if self.cleanupMode == .viewController {
      // trigger cleanup
      self.cleanup();
    };
  };
  
  // MARK: - RNICleanable
  // --------------------
  
  public func cleanup(){
    guard #available(iOS 14.0, *),
          self.shouldEnableCleanup,
          !self.didTriggerCleanup
    else { return };
    
    self.didTriggerCleanup = true;
    
    self.button.contextMenuInteraction?.dismissMenu();
    self.detachFromParentVC();
    
    #if DEBUG
    NotificationCenter.default.removeObserver(self);
    #endif
  };
  
  // MARK: - RNIJSComponentWillUnmountNotifiable
  // -------------------------------------------
  
  public func notifyOnJSComponentWillUnmount(){
    guard self.cleanupMode == .reactComponentWillUnmount
    else { return };
    
    self.cleanup();
  };
};
